import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/media_identity.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ConversationFileStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_media_isolation_');
    store = ConversationFileStore(root);
  });
  tearDown(() => root.delete(recursive: true));

  CapturedConversation capture(String owner, String id, String path,
          {String? proofOwner,
          DateTime? at,
          DateTime? polledAt,
          String type = 'image'}) =>
      CapturedConversation(
        stableKey: 'customer:$owner',
        customerName: owner,
        customerExternalId: owner,
        capturedAt: polledAt ?? at ?? DateTime.utc(2026, 10, 15),
        messages: [
          CapturedMessage(
            stableId: id,
            direction: 'incoming',
            body: '[Customer sent an $type]',
            sender: owner,
            sentAt: at,
            axPath: 'test',
            media: [
              CapturedMedia(
                type: type,
                path: path,
                verifiedCustomerId: proofOwner,
                visualFingerprint: '0123456789abcdef',
              ),
            ],
          ),
        ],
      );

  for (final type in ['image', 'video']) {
    test(
        '$type same send timestamp is deduplicated across polls, restart, and legacy IDs',
        () async {
      final sentAt = DateTime.utc(2026, 10, 15, 3, 24, 27);
      final path = await store.saveMedia(
          userId: 'buyer-a', filename: 'media.png', bytes: [1, 2, 3]);
      final first = await store.appendCapture(capture(
          'buyer-a', 'visible-$type:same-digest:100', path,
          type: type, at: sentAt));
      expect(first.insertedIncomingIds, ['visible-$type:same-digest:100']);
      final restarted = ConversationFileStore(root);
      for (final id in [
        'visible-$type:same-digest:200',
        'visible-$type:same-digest'
      ]) {
        final repeated = await restarted.appendCapture(capture(
            'buyer-a', id, path,
            at: sentAt, polledAt: DateTime.utc(2026, 10, 16), type: type));
        expect(repeated.changed, 0);
        expect(repeated.insertedIncomingIds, isEmpty);
      }
      expect(
          await restarted.hasCapturedMediaContent(
              'buyer-a', type, 'same-digest'),
          isTrue);
      expect((await restarted.read('buyer-a'))!['messages'], hasLength(1));
      expect(
          await restarted.hasCapturedMediaContent(
              'buyer-b', type, 'same-digest'),
          isFalse);
    });

    test('$type identical bytes at each new JD timestamp are new incoming work',
        () async {
      final path = await store
          .saveMedia(userId: 'buyer-a', filename: 'same.png', bytes: [1, 2, 3]);
      final firstAt = DateTime.utc(2026, 9, 24, 8, 16, 16);
      final times = [
        firstAt,
        firstAt.add(const Duration(seconds: 1)),
        DateTime.utc(2026, 10, 16, 3, 24, 27)
      ];
      for (final at in times) {
        final restarted = ConversationFileStore(root);
        expect(
            await restarted.hasCapturedMediaEvent(
                'buyer-a', type, 'same-digest',
                sentAt: at),
            isFalse);
        final id = mediaMessageStableId(type, 'same-digest', at);
        final added = await restarted
            .appendCapture(capture('buyer-a', id, path, type: type, at: at));
        expect(added.insertedIncomingIds, [id]);
        expect(
            (await restarted.appendCapture(capture('buyer-a', id, path,
                    type: type,
                    at: at,
                    polledAt: at.add(const Duration(minutes: 2)))))
                .changed,
            0);
        expect(
            await restarted.hasCapturedMediaEvent(
                'buyer-a', type, 'same-digest',
                sentAt: at),
            isTrue);
      }
      final messages = (await store.read('buyer-a'))!['messages'] as List;
      expect(messages, hasLength(3));
      expect(messages.map((m) => m['media'][0]['path']).toSet(), {path});
      expect(
          await Directory('${store.mediaDirectory.path}/buyer-a').list().length,
          1);
    });

    test('$type missing send time cannot turn a later poll into a resend',
        () async {
      final path = await store
          .saveMedia(userId: 'buyer-a', filename: 'same.png', bytes: [1, 2, 3]);
      await store.appendCapture(
          capture('buyer-a', 'visible-$type:same-digest', path, type: type));
      final repeated = await store.appendCapture(capture(
          'buyer-a', 'visible-$type:same-digest:later-poll', path,
          type: type, polledAt: DateTime.utc(2026, 10, 17)));
      expect(repeated.insertedIncomingIds, isEmpty);
      final knownAt = DateTime.utc(2026, 10, 17, 3, 24, 27);
      final id = mediaMessageStableId(type, 'same-digest', knownAt);
      expect(
          (await store.appendCapture(
                  capture('buyer-a', id, path, type: type, at: knownAt)))
              .insertedIncomingIds,
          [id]);
    });
  }

  test('a failed new upload cannot silently reuse an older readable video',
      () async {
    final oldAt = DateTime.utc(2026, 10, 16, 3, 41, 1);
    final newAt = DateTime.utc(2026, 10, 16, 3, 48, 4);
    final path = await store
        .saveMedia(userId: 'buyer-a', filename: 'old.mp4', bytes: [1, 2]);
    await store.appendCapture(capture(
        'buyer-a', mediaMessageStableId('video', 'old', oldAt), path,
        at: oldAt, type: 'video'));
    await store.recordMediaCaptureFailure('buyer-a', 'video',
        sentAt: newAt, reason: 'video_message_reference_unavailable');
    final restarted = ConversationFileStore(root);
    final failure =
        (await restarted.read('buyer-a'))!['unavailable_customer_media'] as Map;
    expect(failure['sent_at'], newAt.toIso8601String());
    expect((await restarted.read('buyer-a'))!['messages'], hasLength(1));
    final newPath = await store
        .saveMedia(userId: 'buyer-a', filename: 'new.mp4', bytes: [3, 4]);
    await store.appendCapture(capture(
        'buyer-a', mediaMessageStableId('video', 'new', newAt), newPath,
        at: newAt, type: 'video'));
    expect(
        (await store.read('buyer-a'))!['unavailable_customer_media'], isNull);
    await store.recordMediaCaptureFailure('buyer-a', 'video',
        sentAt: newAt, reason: 'later_clipped_preview');
    expect(
        (await store.read('buyer-a'))!['unavailable_customer_media'], isNull);
    expect(await store.read('buyer-b'), isNull);
  });

  test('unknown send time cannot create a fabricated missing-upload event',
      () async {
    await store.recordMediaCaptureFailure('buyer-a', 'video',
        sentAt: null, reason: 'unknown_timestamp');
    expect(await store.read('buyer-a'), isNull);
  });

  test('two different images with the same perceptual hash are not discarded',
      () async {
    final path = await store
        .saveMedia(userId: 'buyer-a', filename: 'one.png', bytes: [1]);
    await store.appendCapture(capture('buyer-a', 'visible-image:first', path));
    final other = await store
        .saveMedia(userId: 'buyer-a', filename: 'two.png', bytes: [2]);
    expect(
        (await store.appendCapture(
                capture('buyer-a', 'visible-image:second', other)))
            .changed,
        1);
    expect((await store.read('buyer-a'))!['messages'], hasLength(2));
  });

  test('customer-specific copies remain separate even for identical bytes',
      () async {
    final a = await store
        .saveMedia(userId: 'buyer-a', filename: 'one.png', bytes: [1, 2]);
    final b = await store
        .saveMedia(userId: 'buyer-b', filename: 'one.png', bytes: [1, 2]);
    expect(a, isNot(b));
    await store.appendCapture(
        capture('buyer-a', 'visible-image:shared', a, proofOwner: 'buyer-a'));
    await store.appendCapture(
        capture('buyer-b', 'visible-image:shared', b, proofOwner: 'buyer-b'));
    expect((await store.read('buyer-a'))!['messages'], hasLength(1));
    expect((await store.read('buyer-b'))!['messages'], hasLength(1));
  });

  test(
      'foreign media paths and conflicting owner proofs are rejected without outer proof',
      () async {
    final foreign = await store
        .saveMedia(userId: 'buyer-b', filename: 'one.png', bytes: [1, 2]);
    await expectLater(
        () => store.appendCapture(
            capture('buyer-a', 'visible-image:foreign', foreign)),
        throwsStateError);
    final own = await store
        .saveMedia(userId: 'buyer-a', filename: 'one.png', bytes: [1, 2]);
    await expectLater(
        () => store.appendCapture(capture(
            'buyer-a', 'visible-image:foreign-proof', own,
            proofOwner: 'buyer-b')),
        throwsStateError);
    expect(await store.read('buyer-a'), isNull);
  });

  test(
      'a symlink inside one customer directory cannot read another customer media',
      () async {
    final foreign = await store
        .saveMedia(userId: 'buyer-b', filename: 'one.png', bytes: [1, 2]);
    final own = Directory('${store.mediaDirectory.path}/buyer-a');
    await own.create();
    final link = await Link('${own.path}/foreign.png').create(foreign);
    await expectLater(
        () => store.appendCapture(
            capture('buyer-a', 'visible-image:symlink', link.path)),
        throwsStateError);
  });

  const channel = MethodChannel('jd.media.owner.regression-test');
  for (final owner in [null, 'buyer-b', 'buyer-a']) {
    for (final verification in [
      null,
      'timestamp_only',
      'visible_customer_region'
    ]) {
      test(
          'image/video payload requires exact visible-owner proof: $owner / $verification',
          () async {
        final adapter = MacOSCaptureAdapter(channel: channel);
        addTearDown(adapter.close);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                channel,
                (call) async => {
                      'kind':
                          call.method == 'downloadVideoAt' ? 'video' : 'image',
                      'dataBase64': 'AQID',
                      'path': '${root.path}/video.mp4',
                      if (owner != null) 'verifiedCustomerId': owner,
                      if (verification != null)
                        'ownershipVerification': verification,
                    });
        addTearDown(() => TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null));
        final image = adapter.captureImageRegion(
            expectedCustomer: 'buyer-a',
            windowId: 1,
            x: .2,
            y: .2,
            width: .2,
            height: .2);
        final video = adapter.downloadVideoAt(
            expectedCustomer: 'buyer-a',
            windowId: 1,
            x: .2,
            y: .2,
            width: .2,
            height: .2,
            destinationDirectory: root.path);
        if (owner == 'buyer-a' && verification == 'visible_customer_region') {
          expect((await image).bytes, [1, 2, 3]);
          expect((await video).path, '${root.path}/video.mp4');
        } else {
          await Future.wait([
            expectLater(
                image,
                throwsA(isA<PlatformException>()
                    .having((e) => e.code, 'code', 'media_owner_unverified'))),
            expectLater(
                video,
                throwsA(isA<PlatformException>()
                    .having((e) => e.code, 'code', 'media_owner_unverified'))),
          ]);
        }
      });
    }
  }
}
