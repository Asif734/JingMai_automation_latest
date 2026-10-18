import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/attachment_download_queue.dart';

Future<void> until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}

void main() {
  late Directory root;
  setUp(
      () async => root = await Directory.systemTemp.createTemp('jd_exports_'));
  tearDown(() => root.delete(recursive: true));
  AttachmentDownloadTicket ticket(String customer, int second) =>
      AttachmentDownloadTicket(
          token: '$customer-$second',
          customer: customer,
          eventKey: 'upload:$second:0',
          sentAt: DateTime.utc(2026, 10, 18, 4, 32, second),
          startedAt: DateTime.now().toUtc(),
          directory:
              '/private/media/$customer/attachment_exports/attachment_$second',
          originalName: 'same-file.mp4');

  test(
      'same event dedups; new timestamps persist and do not starve another customer',
      () async {
    final gate = Completer<bool>();
    final processed = <String>[];
    final idle = <String>[];
    final first = ticket('a', 4);
    final next = ticket('a', 5);
    final other = ticket('b', 4);
    final queue = AttachmentDownloadQueue(root,
        enabled: () => true,
        poll: (t) async {
          processed.add(t.key);
          if (t.key == first.key) return gate.future;
          return true;
        },
        failed: (t, e) async => fail('$e'),
        onIdle: idle.add);
    addTearDown(queue.close);
    await queue.enqueue(first);
    await queue.enqueue(first);
    await queue.enqueue(next);
    await queue.enqueue(other);
    await until(() => idle.contains('b'));
    expect(processed.where((key) => key == first.key), hasLength(1));
    expect(processed, isNot(contains(next.key)));
    expect(queue.hasCustomer('a'), isTrue);
    gate.complete(true);
    await until(() => idle.contains('a'));
    expect(processed, [first.key, other.key, next.key]);
    expect(await root.list().length, 0);
  });

  test(
      'bounded download timeout releases its customer even if failure reporting throws',
      () async {
    final idle = <String>[];
    final failed = <String>[];
    final errors = <Object>[];
    final queue = AttachmentDownloadQueue(root,
        enabled: () => true,
        timeout: const Duration(milliseconds: 75),
        pollInterval: const Duration(milliseconds: 5),
        poll: (t) async => t.customer != 'stalled',
        failed: (t, e) async {
          failed.add(t.customer);
          throw StateError('log unavailable');
        },
        onError: (e, s) => errors.add(e),
        onIdle: idle.add);
    addTearDown(queue.close);
    await queue.enqueue(ticket('stalled', 4));
    await queue.enqueue(ticket('normal', 4));
    await until(() => idle.contains('normal'));
    await until(() => idle.contains('stalled'));
    expect(failed, ['stalled']);
    expect(errors.any((e) => e is TimeoutException), isTrue);
    expect(errors.any((e) => e is StateError), isTrue);
    expect(queue.hasCustomer('stalled'), isFalse);
  });

  test('poll exception cannot strand the queue or another customer', () async {
    final idle = <String>[];
    final failed = <String>[];
    final queue = AttachmentDownloadQueue(root,
        enabled: () => true,
        maximumWorkers: 1,
        poll: (t) async {
          if (t.customer == 'bad') throw StateError('missing original');
          return true;
        },
        failed: (t, e) async => failed.add(t.customer),
        onIdle: idle.add);
    addTearDown(queue.close);
    await queue.enqueue(ticket('bad', 4));
    await queue.enqueue(ticket('good', 4));
    await until(() => idle.contains('good'));
    expect(failed, ['bad']);
    expect(queue.hasCustomer('bad'), isFalse);
  });

  test('restart preserves customer, event timestamp and private directory',
      () async {
    final original = ticket('a', 4);
    final paused = AttachmentDownloadQueue(root,
        enabled: () => false,
        poll: (t) async => false,
        failed: (t, e) async {},
        onIdle: (_) {});
    await paused.enqueue(original);
    paused.close();
    final seen = <AttachmentDownloadTicket>[];
    final queue = AttachmentDownloadQueue(root,
        enabled: () => true,
        poll: (t) async {
          seen.add(t);
          return true;
        },
        failed: (t, e) async => fail('$e'),
        onIdle: (_) {});
    addTearDown(queue.close);
    await queue.resume();
    await until(() => !queue.hasCustomer('a'));
    expect(seen.single.toJson(), original.toJson());
  });

  test('corrupt journal is retained as invalid and does not block valid work',
      () async {
    final bad = File('${root.path}/broken.json');
    await bad.writeAsString('{broken');
    final forged = ticket('forged', 4);
    final forgedJson = forged.toJson()..['token'] = '';
    final name = sha256.convert(utf8.encode(forged.key));
    await File('${root.path}/$name.json').writeAsString(jsonEncode(forgedJson));
    final errors = <Object>[];
    final idle = <String>[];
    final queue = AttachmentDownloadQueue(root,
        enabled: () => true,
        poll: (t) async => true,
        failed: (t, e) async {},
        onError: (e, s) => errors.add(e),
        onIdle: idle.add);
    addTearDown(queue.close);
    await queue.enqueue(ticket('good', 4));
    await until(() => idle.contains('good'));
    expect(queue.hasCustomer('forged'), isFalse);
    expect(errors, hasLength(2));
    expect(await File('${bad.path}.invalid').exists(), isTrue);
  });
}
