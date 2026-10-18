import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/video_capture_queue.dart';
import 'package:jd_automation/capture/media_process_runner.dart';

Future<void> until(bool Function() condition) async {
  final due = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(due)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_video_jobs_');
  });
  tearDown(() => root.delete(recursive: true));
  VideoCaptureJob job(String owner, int second,
          {String digest = 'same-file'}) =>
      VideoCaptureJob(
          customer: owner,
          path: '/private/$owner/$digest.mp4',
          digest: digest,
          sentAt: DateTime.utc(2026, 10, 16, 4, 27, second),
          fingerprint: 'thumbnail');

  test(
      'all timestamps are queued, same event dedups, other customer is not blocked',
      () async {
    final gate = Completer<void>();
    final finished = <String>[];
    final errors = <Object>[];
    final queue = VideoCaptureQueue(root,
        enabled: () => true,
        onError: (e, s) => errors.add(e),
        process: (j) async {
          if (j.customer == 'a' && j.sentAt!.second == 20) await gate.future;
          finished.add(j.key);
        });
    addTearDown(queue.close);
    expect(await queue.enqueue(job('a', 20)), isTrue);
    expect(await queue.enqueue(job('a', 20)), isFalse);
    expect(await queue.enqueue(job('a', 21)), isTrue);
    expect(await queue.enqueue(job('b', 20)), isTrue);
    await until(() => finished.contains(job('b', 20).key));
    expect(finished, isNot(contains(job('a', 21).key)));
    expect(queue.hasCustomer('a'), isTrue);
    gate.complete();
    await until(() => !queue.hasCustomer('a') && !queue.hasCustomer('b'));
    expect(finished.toSet(),
        {job('a', 20).key, job('a', 21).key, job('b', 20).key});
    expect(errors, isEmpty);
    expect(await root.list().length, 0);
  });
  test('event hash and timestamp survive restart before decoding', () async {
    final stopped = VideoCaptureQueue(root,
        enabled: () => false, process: (j) async {}, onError: (e, s) {});
    await stopped.enqueue(job('a', 20));
    await stopped.enqueue(job('a', 21));
    stopped.close();
    final seen = <VideoCaptureJob>[];
    final restarted = VideoCaptureQueue(root,
        enabled: () => true,
        process: (j) async {
          seen.add(j);
        },
        onError: (e, s) => fail('$e'));
    addTearDown(restarted.close);
    await restarted.resume();
    await until(() => seen.length == 2 && !restarted.hasCustomer('a'));
    expect(seen.map((j) => j.messageId).toSet(), hasLength(2));
    expect(seen.map((j) => j.digest).toSet(), {'same-file'});
  });
  test('decoder timeout finishes failed event and releases customer generation',
      () async {
    final failed = <String>[];
    final ready = <String>[];
    final done = <String>[];
    final queue = VideoCaptureQueue(root,
        enabled: () => true,
        onIdle: ready.add,
        onError: (e, s) => fail('$e'),
        process: (j) async {
          if (j.customer == 'stalled') {
            try {
              await const MediaProcessRunner().run(
                  '/bin/sh', ['-c', "trap '' TERM; exec /bin/sleep 30"],
                  timeout: const Duration(milliseconds: 100));
            } on MediaProcessTimedOut {
              failed.add(j.messageId);
            }
          }
          done.add(j.key);
        });
    addTearDown(queue.close);
    await queue.enqueue(job('stalled', 20));
    await queue.enqueue(job('normal', 20));
    await until(() => done.contains(job('normal', 20).key));
    expect(queue.hasCustomer('stalled'), isTrue);
    await until(() => ready.contains('stalled'));
    expect(failed, [job('stalled', 20).messageId]);
    expect(queue.hasCustomer('stalled'), isFalse);
    expect(ready, contains('normal'));
  });
  test('one failed job releases its worker and never starves another customer',
      () async {
    final errors = <Object>[];
    final seen = <String>[];
    final queue = VideoCaptureQueue(root,
        maximumWorkers: 1,
        enabled: () => true,
        onError: (e, s) => errors.add(e),
        process: (j) async {
          if (j.customer == 'bad') throw StateError('storage unavailable');
          seen.add(j.customer);
        });
    addTearDown(queue.close);
    await queue.enqueue(job('bad', 20));
    await queue.enqueue(job('good', 20));
    await until(() => seen.contains('good') && !queue.hasCustomer('good'));
    expect(queue.hasCustomer('bad'), isTrue);
    expect(errors, isNotEmpty);
  });
  test('malformed unrelated journal does not poison valid media jobs',
      () async {
    final stopped = VideoCaptureQueue(root,
        enabled: () => false, process: (j) async {}, onError: (e, s) {});
    await stopped.enqueue(job('a', 20));
    stopped.close();
    await File('${root.path}/damaged.json').writeAsString('{broken');
    final errors = <Object>[];
    final seen = <String>[];
    final queue = VideoCaptureQueue(root,
        enabled: () => true,
        onError: (e, s) => errors.add(e),
        process: (j) async {
          seen.add(j.customer);
        });
    addTearDown(queue.close);
    await queue.resume();
    await until(() => seen.isNotEmpty && !queue.hasCustomer('a'));
    expect(seen, ['a']);
    expect(errors, hasLength(1));
  });
}
