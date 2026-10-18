import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_acquisition.dart';
import 'package:jd_automation/capture/reply_message_scope.dart';
import 'package:jd_automation/capture/video_capture_queue.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/media_identity.dart';
import 'package:jd_automation/storage/reply_outbox.dart';

void main() {
  const owner = 'jd_41aeec7741d05';
  const digest =
      'f84d688641ffed130e7314605b8876689dbca44117a917fbb3997dcf2d91e2c3';
  final four = DateTime.utc(2026, 10, 18, 8);
  final five = four.add(const Duration(hours: 1));
  String id(DateTime at) => mediaMessageStableId('video', digest, at);

  test('new original and ready frames change input; duplicate scans never do',
      () {
    final versions = MediaEvidenceVersions();
    expect(
        versions.record(owner, id(four), MediaEvidenceStage.original), isTrue);
    expect(versions[owner], 1);
    expect(versions.record(owner, id(four), MediaEvidenceStage.ready), isTrue);
    for (var n = 0; n < 50; n++) {
      for (final stage in MediaEvidenceStage.values) {
        expect(versions.record(owner, id(four), stage), isFalse);
      }
    }
    expect(versions[owner], 2);
    expect(versions['other'], isNull);
    expect(versions.record('other', id(four), MediaEvidenceStage.original),
        isTrue);
    expect(versions['other'], 1);
    expect(versions[owner], 2);
  });

  test(
      '4 PM and 5 PM same video have separate input revisions and answer scopes',
      () {
    final versions = MediaEvidenceVersions();
    versions.record(owner, id(four), MediaEvidenceStage.ready);
    final draft = withMediaEvidenceRevision(
        AiDraft.fromJson(
            {'reply': 'The first video shows an attendance machine.'},
            mediaBaseUrl: Uri()),
        session: 'session',
        revision: versions[owner]!);
    expect(versions.record(owner, id(four), MediaEvidenceStage.ready), isFalse);
    expect(
        hasNewerMediaEvidence(draft,
            session: 'session', revision: versions[owner]!),
        isFalse);
    expect(versions.record(owner, id(five), MediaEvidenceStage.ready), isTrue);
    expect(
        hasNewerMediaEvidence(draft,
            session: 'session', revision: versions[owner]!),
        isTrue);
    final messages = [
      for (final at in [four, five])
        <String, dynamic>{
          'id': id(at),
          'direction': 'incoming',
          'sent_at': at.toIso8601String(),
          'body': '[Customer sent a video]',
        },
    ];
    final firstReply = <String, dynamic>{
      'direction': 'outgoing',
      'source': 'generated_reply',
      'delivery_status': 'sent',
      'body': draft.reply,
      'sent_at': four.add(const Duration(seconds: 20)).toIso8601String(),
      'reply_metadata': {
        'raw_response': {'delivery_batch_end_message_id': id(four)}
      },
    };
    expect(
        replyAnswersIncoming(
            reply: firstReply, incomingId: id(four), messages: messages),
        isTrue);
    expect(
        replyAnswersIncoming(
            reply: firstReply, incomingId: id(five), messages: messages),
        isFalse);
  });

  test('generation survives polling and is durably delivered exactly once',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_media_revision_delivery_');
    addTearDown(() => root.delete(recursive: true));
    final versions = MediaEvidenceVersions();
    final outbox = ReplyOutbox(Directory('${root.path}/outbox'));
    versions.record(owner, id(four), MediaEvidenceStage.original);
    versions.record(owner, id(four), MediaEvidenceStage.ready);
    final startedAtRevision = versions[owner]!;
    final gate = Completer<AiDraft>();
    final delivered = <String>[];
    final generation = () async {
      var draft = await gate.future;
      if (versions[owner] != startedAtRevision) {
        fail('Duplicate media reads must not supersede a returned draft');
      }
      draft = withMediaEvidenceRevision(draft,
          session: 'session', revision: startedAtRevision);
      final item = OutboxReply(
          userId: owner,
          batchEndMessageId: id(four),
          draft: draft,
          createdAt: four);
      await outbox.save(item);
      Future<bool> send() => outbox.sendReady(item,
          send: (answer) async => delivered.add(answer.reply),
          definitelyBeforeSend: (_) => false);
      expect(await send(), isTrue);
      expect(await send(), isFalse);
    }();
    for (var poll = 0; poll < 25; poll++) {
      versions.record(owner, id(four), MediaEvidenceStage.original);
      versions.record(owner, id(four), MediaEvidenceStage.ready);
      await Future<void>.delayed(Duration.zero);
    }
    gate.complete(AiDraft.fromJson(
        {'reply': 'I can see the attendance machine in your video.'},
        mediaBaseUrl: Uri()));
    await generation;
    expect(delivered, ['I can see the attendance machine in your video.']);
    expect((await outbox.pending()).single.state, 'sent');
    // The later resend is another durable reply, not a replay of the first.
    versions.record(owner, id(five), MediaEvidenceStage.ready);
    final later = OutboxReply(
        userId: owner,
        batchEndMessageId: id(five),
        draft: AiDraft.fromJson({'reply': 'I received your new video.'},
            mediaBaseUrl: Uri()),
        createdAt: five);
    await outbox.save(later);
    expect(
        await outbox.sendReady(later,
            send: (d) async => delivered.add(d.reply),
            definitelyBeforeSend: (_) => false),
        isTrue);
    expect(delivered, hasLength(2));
  });

  test('an already queued video does not become a new original on every poll',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_media_revision_queue_');
    addTearDown(() => root.delete(recursive: true));
    final versions = MediaEvidenceVersions();
    final queue = VideoCaptureQueue(root,
        enabled: () => false,
        process: (_) async {},
        onError: (e, s) => fail('$e'));
    addTearDown(queue.close);
    Future<bool> receive(DateTime at) async {
      final job = VideoCaptureJob(
          customer: owner,
          path: '/private/owned.mp4',
          digest: digest,
          sentAt: at,
          fingerprint: 'same');
      final enqueued = await queue.enqueue(job);
      if (enqueued) {
        versions.record(owner, job.messageId, MediaEvidenceStage.original);
      }
      return enqueued;
    }

    expect(await receive(four), isTrue);
    for (var poll = 0; poll < 20; poll++) {
      expect(await receive(four), isFalse);
    }
    expect(versions[owner], 1);
    expect(await receive(five), isTrue);
    expect(versions[owner], 2);
  });

  test('automatic polling cannot increment revisions directly', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('_mediaEvidenceVersions.update(')));
    final captureLoop = main.substring(
        main.indexOf('Future<CapturedConversation?> _captureWithVisibleMedia('),
        main.indexOf('Future<void> _probeRecentMediaCache('));
    expect(RegExp(r'_mediaEvidenceVersions.record\(').allMatches(captureLoop),
        hasLength(1),
        reason: 'Only a newly persisted image, not a duplicate cache read');
    final enqueue = main.substring(
        main.indexOf('Future<bool> _enqueueDownloadedVideo('),
        main.indexOf('Future<void> _completeVideoCaptureJob('));
    expect(enqueue.indexOf('if (!enqueued) return false;'),
        lessThan(enqueue.indexOf('_mediaEvidenceVersions.record(')));
  });
}
