import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/runtime/ui_operation_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  UiOperationScheduler scheduler(
      {Future<void> Function(UiOperationContext)? begin,
      Future<void> Function(UiOperationContext)? end,
      Future<void> Function(UiOperationContext)? cancel,
      Duration fairness = const Duration(seconds: 5)}) {
    final value = UiOperationScheduler(
        beginNative: begin ?? (_) async {},
        endNative: end ?? (_) async {},
        cancelNative: cancel ?? (_) async {},
        recoveryTimeout: const Duration(milliseconds: 40),
        fairnessAfter: fairness);
    addTearDown(value.close);
    return value;
  }

  test('serial UI work, ready originals win but aged capture is not starved',
      () async {
    final events = <String>[];
    final entered = Completer<void>(), release = Completer<void>();
    final queue = scheduler();
    final first = queue.schedule(() async {
      entered.complete();
      await release.future;
      events.add('first');
    });
    await entered.future;
    final capture = queue.schedule(() async => events.add('capture'),
        priority: UiPriority.capture);
    final fallback = queue.schedule(() async => events.add('fallback'),
        priority: UiPriority.fallback);
    final reply = queue.schedule(() async => events.add('original'),
        priority: UiPriority.originalReply);
    release.complete();
    await Future.wait([first, capture, fallback, reply]);
    expect(events, ['first', 'original', 'fallback', 'capture']);
    expect(queue.pendingCount, 0);
  });
  test('an aged customer gets a turn ahead of a stream of ready originals',
      () async {
    final events = <String>[];
    final entered = Completer<void>(), release = Completer<void>();
    final queue = scheduler(fairness: const Duration(milliseconds: 10));
    final first = queue.schedule(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final capture = queue.schedule(() async => events.add('capture'),
        priority: UiPriority.capture);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final replies = [
      for (var index = 1; index <= 4; index++)
        queue.schedule(() async => events.add('original$index'),
            priority: UiPriority.originalReply)
    ];
    release.complete();
    await Future.wait([first, capture, ...replies]);
    expect(events,
        ['original1', 'original2', 'original3', 'capture', 'original4']);
  });
  test(
      'hung job cannot release UI before native cancellation acknowledges stop',
      () async {
    final stop = Completer<void>(), entered = Completer<void>();
    var cancelled = false, nextStarted = false;
    final queue = scheduler(cancel: (_) async {
      cancelled = true;
      entered.complete();
      await stop.future;
    });
    final first = queue.schedule(() => Completer<void>().future,
        timeout: const Duration(milliseconds: 20));
    final failed = expectLater(first, throwsA(isA<TimeoutException>()));
    final second = queue.schedule(() async {
      nextStarted = true;
    });
    await entered.future;
    expect(cancelled, isTrue);
    expect(nextStarted, isFalse);
    stop.complete();
    await failed;
    await second;
    expect(nextStarted, isTrue);
  });
  test(
      'missing stop acknowledgement expires caller, not safety fence; recovery resumes',
      () async {
    var stopAllowed = false, nextStarted = false;
    final queue = scheduler(
        cancel: (_) => stopAllowed ? Future.value() : Completer<void>().future);
    final failed = expectLater(
        queue.schedule(() => Completer<void>().future,
            timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()));
    final next = queue.schedule(() async {
      nextStarted = true;
    });
    await failed;
    expect(queue.recoveryPending, isTrue);
    expect(nextStarted, isFalse);
    stopAllowed = true;
    await next.timeout(const Duration(seconds: 2));
    expect(queue.recoveryPending, isFalse);
  });
  test(
      'late Dart continuation retains revoked capability after next customer starts',
      () async {
    final resume = Completer<void>();
    final oldChecked = Completer<Object>();
    final queue = scheduler();
    final first = queue.schedule(() async {
      await resume.future;
      try {
        UiOperationContext.current!.check('A');
        oldChecked.complete('unsafe');
      } catch (error) {
        oldChecked.complete(error);
      }
    }, customer: 'A', timeout: const Duration(milliseconds: 15));
    await expectLater(first, throwsA(isA<TimeoutException>()));
    await queue.schedule(() async {
      UiOperationContext.current!.check('B');
      resume.complete();
    }, customer: 'B');
    expect(await oldChecked.future, isA<UiOperationCancelled>());
  });
  test('queued expiry never starts native job or loses scheduler capacity',
      () async {
    final release = Completer<void>(), entered = Completer<void>();
    final begun = <String>[];
    final queue = scheduler(begin: (c) async => begun.add(c.label));
    final first = queue.schedule(() async {
      entered.complete();
      await release.future;
    }, label: 'active');
    await entered.future;
    await expectLater(
        queue.schedule(() async {},
            label: 'stale', maximumQueueWait: const Duration(milliseconds: 10)),
        throwsA(isA<UiOperationCancelled>()));
    release.complete();
    await first;
    await queue.schedule(() async {}, label: 'fresh');
    expect(begun, ['active', 'fresh']);
  });

  test('operator stop revokes active UI authority and cancels queued jobs',
      () async {
    final entered = Completer<void>(), resume = Completer<void>();
    var nativeStopped = false, queuedRan = false;
    final queue = scheduler(cancel: (_) async {
      nativeStopped = true;
    });
    final active = queue.schedule(() async {
      entered.complete();
      await resume.future;
      UiOperationContext.current!.check();
    });
    final activeFailed =
        expectLater(active, throwsA(isA<UiOperationCancelled>()));
    await entered.future;
    final queued = queue.schedule(() async {
      queuedRan = true;
    });
    final queuedFailed =
        expectLater(queued, throwsA(isA<UiOperationCancelled>()));
    await queue.cancelAll();
    expect(nativeStopped, isTrue);
    expect(queuedRan, isFalse);
    resume.complete();
    await activeFailed;
    await queuedFailed;
    await queue.schedule(() async {});
  });
  test('inner native timeout also cancels before another customer starts',
      () async {
    final events = <String>[];
    final queue = scheduler(cancel: (_) async => events.add('stopped'));
    final failed = expectLater(
        queue.schedule(() async => throw TimeoutException('lost callback')),
        throwsA(isA<TimeoutException>()));
    await queue.schedule(() async => events.add('B'));
    await failed;
    expect(events, ['stopped', 'B']);
  });
  test('job cannot change customer except through verified AX resolution', () {
    final context = UiOperationContext(
        '1', 'capture', DateTime.now().add(const Duration(seconds: 1)), null);
    context.check('jd_4laeec7741d05');
    expect(() => context.check('B'), throwsA(isA<UiOperationCancelled>()));
    context.resolvedFromVerifiedAx('jd_4laeec7741d05', 'jd_41aeec7741d05');
    context.check('jd_41aeec7741d05');
    context.revoke();
    expect(context.check, throwsA(isA<UiOperationCancelled>()));
  });
  test('late adapter calls never cross MethodChannel after cancellation',
      () async {
    const channel = MethodChannel('test/ui-job-fence');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      return {'sent': true, 'customer': 'A', 'reply': 'answer'};
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    final context = UiOperationContext(
        'old', 'send', DateTime.now().add(const Duration(seconds: 1)), 'A')
      ..revoke();
    await expectLater(
        context.run(() =>
            adapter.sendDraftOnce(expectedCustomer: 'A', reply: 'answer')),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'ui_operation_cancelled')));
    expect(calls, 0);
  });
  test('adapter carries exact job ID, customer and clamped native deadline',
      () async {
    const channel = MethodChannel('test/ui-job-metadata');
    final context = UiOperationContext(
        'job-123', 'send', DateTime.now().add(const Duration(seconds: 1)), 'A');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      expect(args['uiOperationId'], 'job-123');
      expect(args['expectedCustomer'], 'A');
      expect(
          args['operationDeadlineMs'], context.deadline.millisecondsSinceEpoch);
      return {'sent': true, 'customer': 'A', 'reply': 'answer'};
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    await context.run(
        () => adapter.sendDraftOnce(expectedCustomer: 'A', reply: 'answer'));
  });
}
