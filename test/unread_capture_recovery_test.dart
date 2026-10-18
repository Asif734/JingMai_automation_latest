import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/unread_capture_recovery.dart';

void main() {
  test('startup unread is stale until a clock or clear-to-unread transition',
      () {
    final tracker = SidebarUnreadTracker();
    final start = DateTime.utc(2026, 10, 15, 5, 0);

    expect(tracker.observe(customer: 'old', unread: true, observedAt: start),
        isFalse);
    expect(
        tracker.observe(
            customer: 'old',
            unread: true,
            observedAt: start.add(const Duration(minutes: 1))),
        isFalse);
    expect(
        tracker.observe(
            customer: 'old',
            unread: false,
            observedAt: start.add(const Duration(minutes: 2))),
        isFalse);
    expect(
        tracker.observe(
            customer: 'old',
            unread: true,
            observedAt: start.add(const Duration(minutes: 2, seconds: 2))),
        isTrue);
  });

  test('a valid JD elapsed badge immediately verifies a new unread turn', () {
    final tracker = SidebarUnreadTracker();
    final now = DateTime.utc(2026, 10, 15, 5, 20, 22);
    expect(
        tracker.observe(
            customer: 'new',
            unread: true,
            unreadAgeSeconds: 7,
            observedAt: now),
        isTrue);
    expect(
        tracker.observe(
            customer: 'invalid',
            unread: true,
            unreadAgeSeconds: 9999,
            observedAt: now),
        isFalse);
  });

  test('recent answered messages cannot pretend to recover a new unread body',
      () {
    final start = DateTime.utc(2026, 10, 7, 6, 25, 10);
    final messages = <Map<String, dynamic>>[
      {
        'id': 'previous-question',
        'direction': 'incoming',
        'sent_at': start.subtract(const Duration(seconds: 8)).toIso8601String()
      },
      {
        'id': 'previous-answer',
        'direction': 'outgoing',
        'sent_at': start.subtract(const Duration(seconds: 5)).toIso8601String()
      },
    ];
    final recovery = UnreadCaptureRecovery(
        customer: 'customer',
        unreadEvidence: 0,
        detectedAt: start,
        knownOutgoingIds: const {},
        knownIncomingIds: UnreadCaptureRecovery.incomingBaseline(messages,
            detectedAt: start, answeredMessageId: 'previous-question'));
    expect(
        recovery.acceptsIncoming('previous-question',
            sentAt: start.subtract(const Duration(seconds: 8)),
            capturedAt: start.add(const Duration(seconds: 3))),
        isFalse);
    expect(recovery.holdingDue(start.add(const Duration(seconds: 20))), isTrue);
  });

  test('already captured but unanswered current-turn body remains recoverable',
      () {
    final start = DateTime.utc(2026, 10, 7, 6, 25, 10);
    final baseline = UnreadCaptureRecovery.incomingBaseline([
      {
        'id': 'old',
        'direction': 'incoming',
        'sent_at': start.subtract(const Duration(minutes: 1)).toIso8601String()
      },
      {
        'id': 'current',
        'direction': 'incoming',
        'sent_at': start.toIso8601String()
      },
    ], detectedAt: start, answeredMessageId: 'old');
    expect(baseline, {'old'});
  });

  test('previous holding reply cannot cancel the 14:25:10 missed-body turn',
      () {
    final start = DateTime.utc(2026, 10, 7, 6, 25, 10);
    final recovery = UnreadCaptureRecovery(
      customer: 'jd_41aeec7741d05',
      unreadEvidence: 0,
      detectedAt: start,
      knownIncomingIds: const {},
      knownOutgoingIds: const {'previous-holding'},
    );
    final history = <Map<String, dynamic>>[
      {
        'id': 'previous-holding',
        'direction': 'outgoing',
        'source': 'sla_fallback',
        'sent_at': '2026-10-07T06:24:59.157774Z'
      },
      {
        'id': 'previous-answer',
        'direction': 'outgoing',
        'source': 'generated_reply',
        'sent_at': '2026-10-07T06:25:00.498378Z'
      },
    ];
    expect(recovery.holdingReplySentAt(history), isNull);
    expect(recovery.holdingDue(start.add(const Duration(seconds: 20))), isTrue);
    expect(recovery.detectedAt.add(UnreadCaptureRecovery.holdingAfter),
        DateTime.utc(2026, 10, 7, 6, 25, 30));
    // Even a late-added OCR/history entry absent from the baseline is old.
    history.first['id'] = 'late-copy-of-old-holding';
    expect(recovery.holdingReplySentAt(history), isNull);
  });

  test('only a new delivered holding reply resolves this recovery', () {
    final start = DateTime.utc(2026, 10, 7, 6, 25, 10);
    final recovery = UnreadCaptureRecovery(
      customer: 'customer',
      unreadEvidence: 0,
      detectedAt: start,
      knownIncomingIds: const {},
      knownOutgoingIds: const {'baseline'},
    );
    final reply = <String, dynamic>{
      'id': 'holding',
      'direction': 'outgoing',
      'source': 'sla_fallback',
      'sent_at': start.add(const Duration(seconds: 20)).toIso8601String(),
      'delivery_status': 'sent',
    };
    expect(recovery.holdingReplySentAt([reply]),
        start.add(const Duration(seconds: 20)));
    reply['delivery_status'] = 'delivery_unknown';
    expect(recovery.holdingReplySentAt([reply]), isNull);
    reply['delivery_status'] = 'sent';
    reply['id'] = 'baseline';
    expect(recovery.holdingReplySentAt([reply]), isNull);
    reply['id'] = 'holding';
    reply['direction'] = 'incoming';
    expect(recovery.holdingReplySentAt([reply]), isNull);
  });

  test('an unread badge preserves the original 20 and 50 second deadlines', () {
    final observedAt = DateTime.utc(2026, 9, 22, 8, 58, 33);
    final detectedAt = UnreadCaptureRecovery.detectedFromBadge(observedAt, 85);
    expect(detectedAt, DateTime.utc(2026, 9, 22, 8, 57, 8));
    expect(detectedAt.add(UnreadCaptureRecovery.holdingAfter),
        DateTime.utc(2026, 9, 22, 8, 57, 28));
    expect(detectedAt.add(UnreadCaptureRecovery.resendAfter),
        DateTime.utc(2026, 9, 22, 8, 57, 58));
    expect(
        UnreadCaptureRecovery.detectedFromBadge(observedAt, 9999), observedAt);
  });

  test('a later badge starts a new turn without an observed clear state', () {
    final handledAt = DateTime.utc(2026, 9, 22, 10, 44, 36);
    final observedAt = DateTime.utc(2026, 9, 22, 10, 46, 18);
    expect(
        UnreadCaptureRecovery.badgeStartedAfterHandled(
            observedAt, 80, handledAt),
        isTrue);
    expect(
        UnreadCaptureRecovery.badgeStartedAfterHandled(
            observedAt, 110, handledAt),
        isFalse);
    expect(
        UnreadCaptureRecovery.badgeStartedAfterHandled(
            observedAt, null, handledAt),
        isFalse);
  });

  test('a late scan uses the actual manual reply time', () {
    final manualReplyAt = DateTime.utc(2026, 9, 23, 2, 33, 47);
    final observedAt = DateTime.utc(2026, 9, 23, 2, 37, 39);
    expect(
        UnreadCaptureRecovery.badgeStartedAfterHandled(
            observedAt, 120, manualReplyAt),
        isTrue);
  });

  test('cache media is rejected when two customers have ambiguous clocks', () {
    UnreadCaptureRecovery recovery(String customer, int second) =>
        UnreadCaptureRecovery(
          customer: customer,
          unreadEvidence: second,
          detectedAt: DateTime.utc(2026, 9, 24, 6, 0, second),
          knownIncomingIds: const {},
          knownOutgoingIds: const {},
        );

    final recoveries = <String, UnreadCaptureRecovery>{
      'customer-a': recovery('customer-a', 2),
      'customer-b': recovery('customer-b', 4),
    };
    final modifiedAt = DateTime.utc(2026, 9, 24, 6, 0, 3);
    expect(
      UnreadCaptureRecovery.cacheClockUniquelyMatches(
        modifiedAt: modifiedAt,
        targetCustomer: 'customer-a',
        recoveries: recoveries,
      ),
      isFalse,
    );

    recoveries['customer-b'] = recovery('customer-b', 20);
    expect(
      UnreadCaptureRecovery.cacheClockUniquelyMatches(
        modifiedAt: modifiedAt,
        targetCustomer: 'customer-a',
        recoveries: recoveries,
      ),
      isTrue,
    );
  });

  test('visible history cannot resolve a newly detected unread turn', () {
    final detectedAt = DateTime.utc(2026, 9, 23, 2, 35, 39);
    final recovery = UnreadCaptureRecovery(
      customer: 'jd_customer',
      unreadEvidence: 12,
      detectedAt: detectedAt,
      knownIncomingIds: const {'known'},
      knownOutgoingIds: const {},
    );

    expect(
        recovery.acceptsIncoming(
          'old-message-captured-late',
          sentAt: DateTime.utc(2026, 9, 22, 4, 29, 23),
          capturedAt: detectedAt.add(const Duration(seconds: 20)),
        ),
        isFalse);
    expect(
        recovery.acceptsIncoming(
          'current-message',
          sentAt: detectedAt,
          capturedAt: detectedAt.add(const Duration(seconds: 2)),
        ),
        isTrue);
    expect(
        recovery.acceptsIncoming(
          'current-image-without-clock',
          capturedAt: detectedAt.add(const Duration(seconds: 2)),
        ),
        isTrue);
    expect(
        recovery.acceptsIncoming(
          'known',
          sentAt: detectedAt,
          capturedAt: detectedAt,
        ),
        isFalse);
  });

  test('late recovery keeps current captured messages out of its baseline', () {
    final detectedAt = DateTime.utc(2026, 9, 23, 3, 6, 53);
    final currentMessageAt = DateTime.utc(2026, 9, 23, 3, 7, 50);
    expect(
        currentMessageAt.isBefore(detectedAt
            .subtract(UnreadCaptureRecovery.detectedTurnClockTolerance)),
        isFalse);
    expect(
        DateTime.utc(2026, 9, 22, 4, 29, 23).isBefore(detectedAt
            .subtract(UnreadCaptureRecovery.detectedTurnClockTolerance)),
        isTrue);
  });

  test('relaxes and holds at twenty seconds, then asks again thirty later', () {
    final start = DateTime.utc(2026, 9, 22, 8);
    final recovery = UnreadCaptureRecovery(
      customer: 'jd_customer',
      unreadEvidence: 12,
      detectedAt: start,
      knownIncomingIds: const {},
      knownOutgoingIds: const {},
    );
    recovery.verifyIncomingSignal(
        senderKey: 'current', sentAt: start, capturedAt: start);

    expect(recovery.useRelaxedBodyOcr(start.add(const Duration(seconds: 19))),
        isFalse);
    expect(recovery.useRelaxedBodyOcr(start.add(const Duration(seconds: 20))),
        isTrue);
    expect(
        recovery.holdingDue(start.add(const Duration(seconds: 19))), isFalse);
    expect(recovery.holdingDue(start.add(const Duration(seconds: 20))), isTrue);
    recovery.lastCaptureAttemptAt = start.add(const Duration(seconds: 5));
    expect(recovery.captureRetryDue(start.add(const Duration(seconds: 7))),
        isFalse);
    expect(recovery.captureRetryDue(start.add(const Duration(seconds: 13))),
        isTrue);

    recovery.lastCaptureAttemptAt = start.add(const Duration(seconds: 13));
    expect(recovery.captureRetryDue(start.add(const Duration(seconds: 14))),
        isFalse);
    recovery.requestImmediateCaptureRetry();
    expect(recovery.captureRetryDue(start.add(const Duration(seconds: 14))),
        isTrue);
    recovery.holdingSent = true;
    recovery.holdingSentAt = start.add(const Duration(seconds: 20));
    expect(
        recovery.holdingDue(start.add(const Duration(seconds: 20))), isFalse);
    expect(recovery.resendDue(start.add(const Duration(seconds: 49))), isFalse);
    expect(recovery.resendDue(start.add(const Duration(seconds: 50))), isTrue);
    recovery.resendSent = true;
    expect(recovery.resendDue(start.add(const Duration(seconds: 90))), isFalse);
    recovery.lastCaptureAttemptAt = start.add(const Duration(seconds: 50));
    expect(recovery.captureRetryDue(start.add(const Duration(seconds: 57))),
        isFalse);
    expect(recovery.captureRetryDue(start.add(const Duration(seconds: 58))),
        isTrue);
  });

  test('late holding message does not cause immediate second message', () {
    final start = DateTime.utc(2026, 9, 22, 8);
    final recovery = UnreadCaptureRecovery(
      customer: 'jd_customer',
      unreadEvidence: 12,
      detectedAt: start,
      knownIncomingIds: const {},
      knownOutgoingIds: const {},
    )
      ..holdingSent = true
      ..holdingSentAt = start.add(const Duration(seconds: 65));
    recovery.verifyIncomingSignal(
        senderKey: 'current', sentAt: start, capturedAt: start);

    expect(recovery.resendDueAt, start.add(const Duration(seconds: 95)));
    expect(recovery.resendDue(start.add(const Duration(seconds: 65))), isFalse);
    expect(recovery.resendDue(start.add(const Duration(seconds: 95))), isTrue);
  });

  test('low-confidence text requires two matching OCR scans', () {
    final recovery = UnreadCaptureRecovery(
      customer: 'jd_customer',
      unreadEvidence: 12,
      detectedAt: DateTime.utc(2026, 9, 22, 8),
      knownIncomingIds: const {},
      knownOutgoingIds: const {},
    );
    expect(recovery.confirmRelaxedBody('  random  text '), isFalse);
    expect(recovery.confirmRelaxedBody('other text'), isFalse);
    expect(recovery.confirmRelaxedBody('other   text'), isTrue);
  });

  test('a stale unread badge cannot verify an old visible sender clock', () {
    final detectedAt = DateTime.utc(2026, 10, 13, 8, 56, 41);
    final recovery = UnreadCaptureRecovery(
      customer: '上海世亦小关',
      unreadEvidence: 12,
      detectedAt: detectedAt,
      knownIncomingIds: const {},
      knownOutgoingIds: const {},
    );

    expect(
      recovery.verifyIncomingSignal(
        senderKey: 'old-17:08:30',
        sentAt: DateTime.utc(2026, 10, 12, 9, 8, 30),
        capturedAt: detectedAt,
      ),
      isFalse,
    );
    expect(recovery.hasVerifiedIncomingSignal, isFalse);
    expect(
      recovery.verifyIncomingSignal(
        senderKey: 'new-16:56:41',
        sentAt: detectedAt,
        capturedAt: detectedAt.add(const Duration(seconds: 3)),
      ),
      isTrue,
    );
    expect(recovery.hasVerifiedIncomingSignal, isTrue);
  });

  test('a recent parsed badge clock can authorize a guarded holding message',
      () {
    final detectedAt = DateTime.utc(2026, 10, 15, 5, 20, 22);
    final recovery = UnreadCaptureRecovery(
      customer: 'jd_customer',
      unreadEvidence: 12,
      detectedAt: detectedAt,
      knownIncomingIds: const {},
      knownOutgoingIds: const {},
      sidebarUnreadVerified: true,
    );

    expect(
        recovery.canSendHoldingAt(detectedAt.add(const Duration(seconds: 20))),
        isTrue);
    expect(
        recovery.canSendHoldingAt(
            detectedAt.add(UnreadCaptureRecovery.verifiedBadgeLifetime)),
        isTrue);
    expect(
        recovery.canSendHoldingAt(detectedAt
            .add(UnreadCaptureRecovery.verifiedBadgeLifetime)
            .add(const Duration(milliseconds: 1))),
        isFalse);
  });

  test('direct media probes are throttled without blocking later retries', () {
    final start = DateTime.utc(2026, 10, 15, 5, 51, 11);
    final recovery = UnreadCaptureRecovery(
      customer: 'jd_customer',
      unreadEvidence: 12,
      detectedAt: start,
      knownIncomingIds: const {},
      knownOutgoingIds: const {},
    );

    expect(recovery.directMediaProbeDue(start), isTrue);
    recovery.recordDirectMediaProbe(start);
    expect(recovery.directMediaProbeDue(start.add(const Duration(seconds: 4))),
        isFalse);
    expect(recovery.directMediaProbeDue(start.add(const Duration(seconds: 5))),
        isTrue);
  });
}
