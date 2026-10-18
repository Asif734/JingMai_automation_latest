import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_acquisition.dart';
import 'package:jd_automation/capture/video_capture_queue.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/reply_outbox.dart';

void main() {
  const customer = 'jd_41aeec7741d05';
  final first = DateTime.utc(2026, 10, 18, 9, 20, 24);
  final later = DateTime.utc(2026, 10, 18, 9, 23, 1);

  test('queued video suppresses only its own preview, including flat posters',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_poster_regression_');
    addTearDown(() => root.delete(recursive: true));
    final queue = VideoCaptureQueue(root,
        enabled: () => false,
        process: (_) async {},
        onError: (e, _) => fail('$e'));
    addTearDown(queue.close);
    final job = VideoCaptureJob(
        customer: customer,
        path: '/owned/video.mp4',
        digest: 'f84d',
        sentAt: first,
        fingerprint: '',
        sourceEventKey: uploadEventKey(first, 0));
    expect(await queue.enqueue(job), isTrue);
    expect(queue.hasEvent(customer, first, uploadEventKey(first, 0)), isTrue);
    expect(queue.hasEvent(customer, first, uploadEventKey(first, 1)), isFalse);
    expect(queue.hasEvent('other', first, uploadEventKey(first, 0)), isFalse);
    expect(queue.hasEvent(customer, later, uploadEventKey(later, 0)), isFalse);
    expect(VideoCaptureJob.fromJson(job.toJson()).sourceEventKey,
        job.sourceEventKey);
  });

  test(
      '17:20 video then duplicate poster then 17:23 video does not discard first answer',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_frozen_video_reply_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final store = await db.history;
    final versions = MediaEvidenceVersions();
    Future<CapturedMessage> video(DateTime at, String digest) async =>
        CapturedMessage(
            stableId:
                'visible-video:$digest:${at.millisecondsSinceEpoch ~/ 1000}',
            direction: 'incoming',
            body: '[Customer sent a video]',
            sentAt: at,
            axPath: 'test',
            media: [
              CapturedMedia(
                  type: 'video',
                  verifiedCustomerId: customer,
                  path: await store.saveMedia(
                      userId: customer, filename: '$digest.mp4', bytes: [1]),
                  sourceEventKey: uploadEventKey(at, 0),
                  captureSource: 'jd_video_cache')
            ]);
    Future<void> capture(CapturedMessage m) async {
      await db.saveCapture(CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          capturedAt: m.sentAt!,
          messages: [m]));
      versions.record(customer, m.stableId, MediaEvidenceStage.ready,
          sentAt: m.sentAt);
    }

    final oldVideo = await video(first, 'f84d');
    await capture(oldVideo);
    final pending = (await db.conversations()).single;
    final revision = versions.revisionThrough(customer, first);
    expect(
        await store.hasOriginalMediaEvent(
            customer, first, uploadEventKey(first, 0)),
        isTrue);
    expect(
        await store.hasOriginalMediaEvent(
            customer, first, uploadEventKey(first, 1)),
        isFalse);
    expect(
        await store.hasOriginalMediaEvent(
            'other', first, uploadEventKey(first, 0)),
        isFalse);
    // Same video poster is skipped BEFORE inserting another message/revision.
    expect((await store.read(customer))!['messages'], hasLength(1));
    final newVideo = await video(later, 'd4e5');
    await capture(newVideo);
    expect(versions.revisionThrough(customer, first), revision);
    final draft = withMediaEvidenceRevision(
        AiDraft.fromJson({
          'reply': 'The first video shows the card feeding and returning.',
          'decision': 'draft',
          'model': 'test',
        }, mediaBaseUrl: Uri()),
        session: 'test',
        revision: revision,
        throughSentAt: first);
    expect(
        hasNewerMediaEvidence(draft,
            session: 'test',
            revision: versions.revisionThrough(
                customer, mediaEvidenceBoundary(draft))),
        isFalse);
    expect(
        await db.saveDraft(pending.id, draft,
            expectedMessageId: oldVideo.stableId),
        1);
    final ready = (await db.nextReadyDelivery())!;
    expect(ready.batchEndMessageId, oldVideo.stableId);
    final outbox = ReplyOutbox(Directory('${root.path}/outbox'));
    final item = OutboxReply(
        userId: customer,
        batchEndMessageId: oldVideo.stableId,
        draft: draft,
        createdAt: first);
    await outbox.save(item);
    var sent = 0;
    expect(
        await outbox.sendReady(item,
            send: (_) async {
              sent++;
            },
            definitelyBeforeSend: (_) => false),
        isTrue);
    expect(
        await db.markReplySent(
            userId: customer, reply: draft.reply, expectedDelivery: ready),
        isTrue);
    expect(sent, 1);
    expect(await db.answeredMessageId(customer), oldVideo.stableId);
    expect(await db.pendingMessageId(customer), newVideo.stableId);
    // A genuine upgrade belonging to the frozen input still invalidates it.
    versions.record(customer, 'late-original', MediaEvidenceStage.ready,
        sentAt: first);
    expect(
        hasNewerMediaEvidence(draft,
            session: 'test',
            revision: versions.revisionThrough(
                customer, mediaEvidenceBoundary(draft))),
        isTrue);
  });

  test('new event cannot inherit old sent fallback or stale holding receipt',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_holding_event_regression_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    // Replay the incident offsets using recent clocks (JD 17:20:24/46,17:23:01).
    final firstAt = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    final heldAt = firstAt.add(const Duration(seconds: 22));
    final nextAt = firstAt.add(const Duration(minutes: 2, seconds: 37));
    Future<void> incoming(String id, DateTime at) => db
        .saveCapture(CapturedConversation(
            stableKey: customer,
            customerName: customer,
            customerExternalId: customer,
            capturedAt: at.add(const Duration(seconds: 4)),
            messages: [
              CapturedMessage(
                  stableId: id,
                  direction: 'incoming',
                  body: id,
                  sentAt: at,
                  axPath: 'test')
            ]))
        .then((_) {});
    await incoming('first-video', firstAt);
    final old = (await db.slaFallbackJob(customer))!;
    expect(
        await db.reserveSlaFallback(
            userId: customer, messageId: old.messageId, dueAt: old.dueAt),
        isTrue);
    expect(
        await db.markSlaFallbackSent(
            userId: customer, messageId: 'first-video', reply: 'Holding'),
        isTrue);
    final sql = await db.database;
    await sql.update(
        'sla_fallbacks', {'sent_at_ms': heldAt.millisecondsSinceEpoch},
        where: 'user_id=?', whereArgs: [customer]);
    // Set the historical receipt clock in this isolated replay fixture.
    final file = File('${root.path}/$customer.json');
    final raw = jsonDecode(await file.readAsString()) as Map;
    for (final m in (raw['messages'] as List).whereType<Map>()) {
      if (m['source'] == 'sla_fallback') {
        m['sent_at'] = heldAt.toIso8601String();
      }
    }
    await file.writeAsString(jsonEncode(raw));
    await incoming('second-video', nextAt);
    final fresh = (await db.slaFallbackJob(customer))!;
    expect(fresh.messageId, 'second-video');
    expect(fresh.dueAt.millisecondsSinceEpoch,
        nextAt.add(const Duration(seconds: 20)).millisecondsSinceEpoch);
    expect(
        await db.reserveSlaFallback(
            userId: customer, messageId: old.messageId, dueAt: old.dueAt),
        isFalse);
    await db.acknowledgeUncapturedHolding(userId: customer, sentAt: heldAt);
    expect(await db.slaFallbackJob(customer), isNotNull);
    await incoming('follow-up', nextAt.add(const Duration(seconds: 3)));
    expect((await db.slaFallbackJob(customer))!.dueAt, fresh.dueAt);
    await db.ensurePendingForUnanswered(customer);
    expect((await db.slaFallbackJob(customer))!.dueAt, fresh.dueAt);
  });
}
