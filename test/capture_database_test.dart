import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('same image resent at a new JD timestamp creates new work', () async {
    final root = await Directory.systemTemp.createTemp('repeated_image_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final firstAt = DateTime.utc(2026, 9, 23, 3, 30);
    const digest = 'same-image-bytes';
    const fingerprint = '01317c7f7f3f0100';

    CapturedConversation turn(DateTime sentAt) => CapturedConversation(
          stableKey: 'customer:repeat-image',
          customerName: 'repeat-image',
          customerExternalId: 'repeat-image',
          capturedAt: sentAt.add(const Duration(seconds: 2)),
          messages: [
            CapturedMessage(
              stableId:
                  'visible-image:$digest:${sentAt.microsecondsSinceEpoch}',
              direction: 'incoming',
              body: '[Customer sent an image; visible portion captured]',
              sentAt: sentAt,
              axPath: 'ocr:visible-image-region',
              media: const [
                CapturedMedia(
                  type: 'image',
                  path: '/tmp/repeated-image.png',
                  captureSource: 'verified_window_crop',
                  visualFingerprint: fingerprint,
                ),
              ],
            ),
          ],
        );

    expect(await database.saveCapture(turn(firstAt)), 1);
    final secondAt = firstAt.add(const Duration(minutes: 15));
    final store = await database.history;
    expect(
        await store.hasSimilarImageFingerprint(
          'repeat-image',
          fingerprint,
          capturedAfter: secondAt,
        ),
        isFalse);
    expect(await store.hasCapturedMediaContent('repeat-image', 'image', digest),
        isTrue);
    expect(await database.saveCapture(turn(secondAt)), 1);
    expect(await database.saveCapture(turn(secondAt)), 0);

    final document = await store.read('repeat-image');
    final incoming = (document!['messages'] as List<Object?>)
        .whereType<Map<String, dynamic>>()
        .where((message) => message['direction'] == 'incoming');
    expect(incoming, hasLength(2));
  });

  test('captured message gives the durable SLA path sole holding ownership',
      () async {
    final root = await Directory.systemTemp.createTemp('sla_owner_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final receivedAt = DateTime.utc(2026, 9, 23, 3, 11, 43);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:jd-owner',
      customerName: 'jd-owner',
      customerExternalId: 'jd-owner',
      capturedAt: receivedAt.add(const Duration(seconds: 4)),
      messages: [
        CapturedMessage(
          stableId: 'incoming-owner-1',
          direction: 'incoming',
          body: 'hi',
          sentAt: receivedAt,
          axPath: 'test',
        ),
      ],
    ));

    expect(await database.hasActiveSlaFallback('jd-owner'), isTrue);
  });

  test('late OCR keeps the original unread fallback deadline', () async {
    final root = await Directory.systemTemp.createTemp('unread_deadline_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final detectedAt = DateTime(2026, 9, 22, 10);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:jd-unread',
      customerName: 'jd-unread',
      customerExternalId: 'jd-unread',
      capturedAt: detectedAt.add(const Duration(seconds: 23)),
      messages: const [
        CapturedMessage(
          stableId: 'late-ocr-1',
          direction: 'incoming',
          body: '请帮我看一下',
          axPath: 'test',
        ),
      ],
    ));
    await database.capSlaFallbackDue(
      userId: 'jd-unread',
      dueAt: detectedAt.add(const Duration(seconds: 20)),
    );
    expect(
      (await database.slaFallbackJob('jd-unread'))?.dueAt,
      detectedAt.add(const Duration(seconds: 20)),
    );
  });

  test(
      'uncaptured holding counts as the single SLA fallback after OCR recovers',
      () async {
    final root = await Directory.systemTemp.createTemp('unread_sla_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final detectedAt = DateTime(2026, 9, 22, 10);
    await (await database.history).appendSlaFallbackSent(
      userId: 'jd-unread',
      messageId: 'unread-event-1',
      reply: '请稍等，我正在核对您刚发来的消息。',
    );
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:jd-unread',
      customerName: 'jd-unread',
      customerExternalId: 'jd-unread',
      capturedAt: detectedAt.add(const Duration(seconds: 16)),
      messages: const [
        CapturedMessage(
          stableId: 'ocr-recovered-1',
          direction: 'incoming',
          body: '请帮我看一下',
          axPath: 'test',
        ),
      ],
    ));
    final pendingJob = await database.slaFallbackJob('jd-unread');
    expect(pendingJob, isNotNull);
    await database.acknowledgeUncapturedHolding(
      userId: 'jd-unread',
      sentAt: detectedAt.add(const Duration(seconds: 12)),
    );
    expect(await database.slaFallbackJob('jd-unread'), isNull);
    expect(await database.hasPendingUnanswered('jd-unread'), isTrue);
    expect(
      await database.reserveSlaFallback(
        userId: 'jd-unread',
        messageId: pendingJob!.messageId,
        dueAt: pendingJob.dueAt,
      ),
      isFalse,
    );
  });

  test('human transfer counter expires, resets, and ignores retried messages',
      () async {
    final root = await Directory.systemTemp.createTemp('human_transfer_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final start = DateTime.utc(2026, 9, 21, 4, 38);
    Future<bool> request(String user, String id, Duration after) =>
        database.recordHumanTransferRequest(
          userId: user,
          messageId: id,
          requestedAt: start.add(after),
        );

    expect(await request('jd-a', 'first', Duration.zero), isFalse);
    expect(await request('jd-a', 'first', const Duration(minutes: 1)), isFalse);
    expect(await request('jd-b', 'own-first', const Duration(minutes: 1)),
        isFalse);
    expect(
        await request('jd-a', 'second', const Duration(minutes: 10)), isTrue);
    expect(
        await request('jd-a', 'second', const Duration(minutes: 10)), isTrue);
    expect(
        await request('jd-a', 'third', const Duration(minutes: 11)), isFalse);
    expect(
        await request('jd-a', 'fourth', const Duration(minutes: 21)), isTrue);
    expect(await request('jd-b', 'late', const Duration(minutes: 12)), isFalse);
    expect(await request('jd-b', 'again', const Duration(minutes: 13)), isTrue);

    final rows = await (await database.database).query(
      'human_transfer_requests',
      where: 'user_id = ?',
      whereArgs: ['jd-a'],
    );
    expect(rows.single['request_count'], 0);
  });

  test('new request pair overwrites and retries an agents-busy review',
      () async {
    final root = await Directory.systemTemp.createTemp('review_retry_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    final morning = DateTime.now().toUtc();
    expect(
      await database.recordHumanTransferRequest(
        userId: 'returning-buyer',
        messageId: 'morning-request',
        requestedAt: morning,
      ),
      isFalse,
    );
    final morningTicket = await database.createHumanReviewTicket(
      userId: 'returning-buyer',
      customerRequest: 'Please transfer me this morning',
      reason: 'Morning review request',
      requestMessageId: 'morning-second-request',
    );
    final morningLog =
        await database.reserveChatTransferLog(ticket: morningTicket);
    await database.updateChatTransferLog(
      id: morningLog!.id,
      status: 'agents_busy',
    );
    await database.markTicketAwaitingCurrentAgent(morningTicket.id);
    expect(
      await database.reserveChatTransferLog(ticket: morningTicket),
      isNull,
    );

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:returning-buyer',
      customerName: 'returning-buyer',
      customerExternalId: 'returning-buyer',
      capturedAt: morning.add(const Duration(hours: 2)),
      messages: const [
        CapturedMessage(
          stableId: 'afternoon-first-request',
          direction: 'incoming',
          body: 'I want another human review',
          axPath: 'ocr',
        ),
      ],
    ));
    expect(await database.hasPendingUnanswered('returning-buyer'), isTrue);

    // A failed earlier attempt does not change the two-request policy. The
    // first new request starts a fresh sequence.
    expect(
      await database.recordHumanTransferRequest(
        userId: 'returning-buyer',
        messageId: 'afternoon-first-request',
        requestedAt: morning.add(const Duration(hours: 2)),
      ),
      isFalse,
    );
    // The second distinct request in the normal ten-minute window triggers a
    // new attempt, despite the earlier agents-busy record.
    expect(
      await database.recordHumanTransferRequest(
        userId: 'returning-buyer',
        messageId: 'afternoon-second-request',
        requestedAt: morning.add(const Duration(hours: 2, minutes: 1)),
      ),
      isTrue,
    );
    final afternoonTicket = await database.createHumanReviewTicket(
      userId: 'returning-buyer',
      customerRequest: 'No, please transfer me',
      reason: 'Afternoon review request',
      requestMessageId: 'afternoon-second-request',
    );
    expect(afternoonTicket.id, morningTicket.id);
    expect(afternoonTicket.customerRequest, 'No, please transfer me');
    expect(afternoonTicket.reason, 'Afternoon review request');
    expect(afternoonTicket.status, 'open');
    expect(await database.hasPendingUnanswered('returning-buyer'), isTrue);

    final retried =
        await database.reserveChatTransferLog(ticket: afternoonTicket);
    expect(retried, isNotNull);
    expect(retried!.id, morningLog.id);
    expect(retried.status, 'pending');
    expect(retried.reason, 'Afternoon review request');
    expect(retried.targetAccount, isNull);
    expect(retried.error, isNull);
  });

  test('transfer welcome reservation rejects the same exact event', () async {
    final root = await Directory.systemTemp.createTemp('welcome_guard_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final now = DateTime(2026, 9, 1, 14);

    expect(
        await database.reserveTransferWelcome(
            userId: 'jd_test', eventKey: 'ocr-shape-a', now: now),
        isTrue);
    expect(await database.latestTransferNoticeAt('jd_test'), now.toUtc());
    expect(
        await database.reserveTransferWelcome(
            userId: 'jd_test',
            eventKey: 'ocr-shape-a',
            now: now.add(const Duration(seconds: 30))),
        isFalse);
    expect(
        await database.reserveTransferWelcome(
            userId: 'jd_test',
            eventKey: 'new-transfer',
            now: now.add(const Duration(seconds: 31))),
        isTrue);

    await database.releaseTransferWelcomeReservation(
      userId: 'jd_test',
      eventKey: 'ocr-shape-a',
    );
    expect(
        await database.reserveTransferWelcome(
            userId: 'jd_test',
            eventKey: 'ocr-shape-a',
            now: now.add(const Duration(minutes: 1))),
        isTrue);
  });

  test('SLA fallback stays separate and final reply remains queued', () async {
    final root = await Directory.systemTemp.createTemp('sla_fallback_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final capturedAt = DateTime(2026, 9, 16, 10);
    const userId = 'sla-customer';
    const messageId = 'customer-message-1';
    const fallback = '请稍等片刻。';

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: capturedAt,
      messages: const [
        CapturedMessage(
          stableId: messageId,
          direction: 'incoming',
          body: 'Please check this for me.',
          axPath: 'test',
        ),
      ],
    ));

    final job = await database.slaFallbackJob(userId);
    expect(job?.messageId, messageId);
    expect(job?.dueAt, capturedAt.add(const Duration(seconds: 20)));
    expect(
        await database.reserveSlaFallback(
            userId: userId, messageId: messageId, dueAt: job!.dueAt),
        isTrue);
    expect(
        await database.reserveSlaFallback(
            userId: userId, messageId: messageId, dueAt: job.dueAt),
        isFalse);
    await database.markSlaFallbackSent(
      userId: userId,
      messageId: messageId,
      reply: fallback,
    );

    expect(await database.hasPendingUnanswered(userId), isTrue);
    expect(await database.pendingMessageId(userId), messageId);
    final afterFallback = await (await database.history).read(userId);
    final fallbackMessages = afterFallback!['messages'] as List<Object?>;
    expect(fallbackMessages, hasLength(2));
    expect((fallbackMessages.last as Map<String, dynamic>)['source'],
        'sla_fallback');

    // OCR will later see the fallback in JD. It must be deduplicated instead
    // of being mistaken for a manual seller answer that cancels AI work.
    final changed = await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: capturedAt.add(const Duration(minutes: 2, seconds: 2)),
      messages: const [
        CapturedMessage(
          stableId: messageId,
          direction: 'incoming',
          body: 'Please check this for me.',
          axPath: 'test',
        ),
        CapturedMessage(
          stableId: 'ocr-fallback',
          direction: 'outgoing',
          body: fallback,
          axPath: 'test',
        ),
      ],
    ));
    expect(changed, 0);
    expect(await database.hasPendingUnanswered(userId), isTrue);

    final pending = (await database.conversations()).single;
    const finalDraft = AiDraft(
      reply: 'Here is the verified answer.',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson:
          '{"reply":"Here is the verified answer.","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}',
    );
    await database.saveDraft(pending.id, finalDraft);
    expect((await database.nextReadyDelivery())?.userId, userId);
    expect(
        await database.markReplySent(userId: userId, reply: finalDraft.reply),
        isTrue);

    final completed = await (await database.history).read(userId);
    final completedMessages = completed!['messages'] as List<Object?>;
    expect(completedMessages, hasLength(3));
    expect((completedMessages.last as Map<String, dynamic>)['body'],
        finalDraft.reply);
    final slaRows = await (await database.database)
        .query('sla_fallbacks', where: 'user_id = ?', whereArgs: [userId]);
    expect(slaRows.single['state'], 'completed');
  });

  test('a real reply cancels a holding message that was already reserved',
      () async {
    final root = await Directory.systemTemp.createTemp('sla_race_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    const userId = 'race-customer';
    const messageId = 'race-message';
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: DateTime(2026, 9, 20, 16),
      messages: const [
        CapturedMessage(
          stableId: messageId,
          direction: 'incoming',
          body: 'Please check this.',
          axPath: 'test',
        ),
      ],
    ));
    final pending = (await database.conversations()).single;
    const draft = AiDraft(
      reply: 'Here is the checked answer.',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson:
          '{"reply":"Here is the checked answer.","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}',
    );
    await database.saveDraft(pending.id, draft, expectedMessageId: messageId);
    expect(
        await database.reserveSlaFallback(
            userId: userId,
            messageId: messageId,
            dueAt: (await database.slaFallbackJob(userId))!.dueAt),
        isTrue);
    expect(
        await database.isSlaFallbackReservedForSend(
            userId: userId, messageId: messageId),
        isTrue);

    expect(await database.markReplySent(userId: userId, reply: draft.reply),
        isTrue);
    expect(
        await database.isSlaFallbackReservedForSend(
            userId: userId, messageId: messageId),
        isFalse);
    expect(
        await database.markSlaFallbackSent(
          userId: userId,
          messageId: messageId,
          reply: 'Please wait while we check.',
        ),
        isFalse);
    final history = await (await database.history).read(userId);
    final messages = (history!['messages'] as List<Object?>)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    expect(messages.where((message) => message['source'] == 'sla_fallback'),
        isEmpty);
  });

  test('answered reserved SLA fallback completes instead of retrying',
      () async {
    final root = await Directory.systemTemp.createTemp('sla_answered_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final capturedAt = DateTime(2026, 10, 14, 3);
    const userId = 'answered-customer';
    const messageId = 'incoming-1';
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: capturedAt,
      messages: const [
        CapturedMessage(
          stableId: messageId,
          direction: 'incoming',
          body: 'Question',
          axPath: 'test',
        ),
      ],
    ));
    final job = (await database.slaFallbackJob(userId))!;
    expect(
      await database.reserveSlaFallback(
        userId: userId,
        messageId: messageId,
        dueAt: job.dueAt,
      ),
      isTrue,
    );

    await database.completeSlaFallbackAfterReply(
      userId: userId,
      messageId: messageId,
    );

    expect(await database.slaFallbackJob(userId), isNull);
    expect(
      (await database.pendingSlaFallbackJobs())
          .where((item) => item.userId == userId),
      isEmpty,
    );
  });

  test('a stale fallback callback cannot reserve a window reset by a reply',
      () async {
    final root = await Directory.systemTemp.createTemp('sla_stale_timer_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    const userId = 'stale-timer-customer';
    final capturedAt = DateTime.now().subtract(const Duration(seconds: 30));
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: capturedAt,
      messages: const [
        CapturedMessage(
          stableId: 'first-message',
          direction: 'incoming',
          body: 'I need help.',
          axPath: 'test',
        ),
        CapturedMessage(
          stableId: 'second-message',
          direction: 'incoming',
          body: 'Please transfer me.',
          axPath: 'test',
        ),
      ],
    ));
    final staleJob = (await database.slaFallbackJob(userId))!;
    final pending = (await database.conversations()).single;
    const draft = AiDraft(
      reply: 'I have handled the first request.',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson:
          '{"reply":"I have handled the first request.","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}',
    );
    await database.saveDraft(pending.id, draft,
        expectedMessageId: 'first-message');
    expect(await database.markReplySent(userId: userId, reply: draft.reply),
        isTrue);

    final resetJob = (await database.slaFallbackJob(userId))!;
    expect(resetJob.messageId, staleJob.messageId);
    expect(resetJob.dueAt, isNot(staleJob.dueAt));
    expect(
        await database.reserveSlaFallback(
          userId: staleJob.userId,
          messageId: staleJob.messageId,
          dueAt: staleJob.dueAt,
        ),
        isFalse);
    expect(
        await database.reserveSlaFallback(
          userId: resetJob.userId,
          messageId: resetJob.messageId,
          dueAt: resetJob.dueAt,
        ),
        isTrue);
  });

  test('delivery failures retain drafts for retry or reconciliation', () async {
    final root = await Directory.systemTemp.createTemp('delivery_retry_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    const userId = 'retry-customer';
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: DateTime(2026, 9, 16, 10),
      messages: const [
        CapturedMessage(
          stableId: 'retry-message',
          direction: 'incoming',
          body: 'Need an answer',
          axPath: 'test',
        ),
      ],
    ));
    final pending = (await database.conversations()).single;
    const draft = AiDraft(
      reply: 'Retained answer',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson:
          '{"reply":"Retained answer","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}',
    );
    await database.saveDraft(pending.id, draft);
    CapturedMessage observed(String body, {bool confirmed = true}) =>
        CapturedMessage(
          stableId: 'observed-reply',
          direction: 'outgoing',
          body: body,
          sentAt: DateTime.now().toUtc(),
          axPath: 'test',
          deliveryConfirmed: confirmed,
        );
    await database.markGeneratedDraftDeliveryFailure(
      userId: userId,
      error: 'pre-click verification failed',
      retryDelay: Duration.zero,
    );
    expect((await database.nextReadyDelivery())?.draft.reply, draft.reply);
    expect(
        await database.confirmObservedGeneratedDraft(
            userId: userId,
            message: observed(draft.reply),
            capturedAt: DateTime.now().toUtc()),
        isFalse);
    expect((await database.nextReadyDelivery())?.draft.reply, draft.reply);

    await database.markGeneratedDraftDeliveryFailure(
      userId: userId,
      error: 'send_unconfirmed',
    );
    expect(await database.nextReadyDelivery(), isNull);
    final rows = await (await database.database)
        .query('generated_drafts', where: 'user_id = ?', whereArgs: [userId]);
    expect(rows, hasLength(1));
    expect(rows.single['delivery_state'], 'retry');
    expect(
        await database.confirmObservedGeneratedDraft(
            userId: userId,
            message: observed('another message'),
            capturedAt: DateTime.now().toUtc()),
        isFalse);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: DateTime.now().toUtc(),
      messages: [observed(draft.reply)],
    ));
    expect(await database.hasUndeliveredDraft(userId), isFalse);
  });

  test('explicit transfer drafts never enter the delivery queue', () async {
    final root = await Directory.systemTemp.createTemp('transfer_draft_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    const userId = 'transfer-customer';
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: DateTime(2026, 9, 29, 11),
      messages: const [
        CapturedMessage(
          stableId: 'transfer-message',
          direction: 'incoming',
          body: 'Transfer me to another agent',
          axPath: 'test',
        ),
      ],
    ));
    final pending = (await database.conversations()).single;
    const draft = AiDraft(
      reply: 'A colleague can continue from here.',
      decision: 'human_review',
      confidence: 1,
      riskLevel: 'high',
      model: 'test',
      usedRecordIds: [],
      actions: ['transfer_to_human'],
      attachments: [],
      rawJson:
          '{"reply":"A colleague can continue from here.","decision":"human_review","confidence":1,"risk_level":"high","model":"test","used_record_ids":[],"actions":["transfer_to_human"],"attachments":[]}',
    );

    await database.saveDraft(
      pending.id,
      draft,
      expectedMessageId: 'transfer-message',
      deliverable: false,
    );

    expect(await database.nextReadyDelivery(), isNull);
    expect(
      await database.isGeneratedDraftReadyForSend(
        userId: userId,
        reply: draft.reply,
      ),
      isFalse,
    );
    final rows = await (await database.database).query(
      'generated_drafts',
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    expect(rows.single['delivery_state'], 'transfer_only');

    final ticket = await database.createHumanReviewTicket(
        userId: userId,
        customerRequest: 'Transfer me to another agent',
        reason: 'explicit request',
        requestMessageId: 'transfer-message');
    // Production starts the handoff before the later draft cleanup. Consuming
    // its cursor must be atomic with that first deletion.
    await database.markTicketContacting(ticket.id);
    expect(await database.answeredMessageId(userId), 'transfer-message');
    await database.discardTransferOnlyDraft(userId);

    expect(await database.hasUndeliveredDraft(userId), isFalse);
    expect(await database.answeredMessageId(userId), 'transfer-message');
    expect(await database.ensurePendingForUnanswered(userId), isFalse);
  });

  test('fallback reservation uses the JD China-time message clock', () async {
    final root = await Directory.systemTemp.createTemp('sla_clock_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    // JD displayed 13:37:40 China time. On a UTC+6 workstation the OCR
    // parser may initially infer the previous local day because 13:37 looks
    // later than the 11:38 local capture clock.
    final capturedAt = DateTime.utc(2026, 9, 16, 5, 38, 52).toLocal();
    final observedClock = DateTime(2026, 9, 15, 13, 37, 40);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:clock',
      customerName: 'clock',
      customerExternalId: 'clock',
      capturedAt: capturedAt,
      messages: [
        CapturedMessage(
          stableId: 'clock-message',
          direction: 'incoming',
          body: 'Please check this.',
          sentAt: observedClock,
          axPath: 'test',
        ),
      ],
    ));

    final job = await database.slaFallbackJob('clock');
    expect(job?.dueAt.toUtc(), DateTime.utc(2026, 9, 16, 5, 38));
  });

  test('later customer messages do not restart the fallback clock', () async {
    final root = await Directory.systemTemp.createTemp('sla_batch_clock_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    const userId = 'jd_41aeec7741d05';
    final firstAt = DateTime.utc(2026, 9, 19, 10, 58, 46);
    final secondAt = DateTime.utc(2026, 9, 19, 10, 59, 37);

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: firstAt,
      messages: [
        CapturedMessage(
          stableId: 'first-message',
          direction: 'incoming',
          body: 'oh...then how to set it up',
          sentAt: firstAt,
          axPath: 'test',
        ),
      ],
    ));

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:$userId',
      customerName: userId,
      customerExternalId: userId,
      capturedAt: secondAt,
      messages: [
        CapturedMessage(
          stableId: 'second-message',
          direction: 'incoming',
          body: 'is it possible to change ribbon m880 with m880DaT',
          sentAt: secondAt,
          axPath: 'test',
        ),
      ],
    ));

    final job = await database.slaFallbackJob(userId);
    expect(job?.messageId, 'second-message');
    expect(
      job?.dueAt.toUtc(),
      firstAt.add(const Duration(seconds: 20)),
    );
  });

  test('version 7 migration protects customers already waiting', () async {
    final root = await Directory.systemTemp.createTemp('sla_migration_test_');
    final path = '${root.path}/jd_automation.sqlite3';
    sqfliteFfiInit();
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE pending_customers (
            id INTEGER PRIMARY KEY,
            user_id TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            stable_key TEXT NOT NULL,
            newest_message_id TEXT NOT NULL,
            enqueued_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
          )''');
          await db.execute('''CREATE TABLE generated_drafts (
            user_id TEXT PRIMARY KEY,
            pending_id INTEGER NOT NULL,
            reply TEXT NOT NULL,
            model TEXT NOT NULL,
            raw_json TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL
          )''');
          await db.execute('''CREATE TABLE conversation_control (
            user_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            resume_after_message_id TEXT,
            updated_at_ms INTEGER NOT NULL
          )''');
        },
      ),
    );
    const enqueuedAt = 1800000000000;
    await legacy.insert('pending_customers', {
      'user_id': 'waiting-at-upgrade',
      'display_name': 'Waiting customer',
      'stable_key': 'customer:waiting-at-upgrade',
      'newest_message_id': 'existing-message',
      'enqueued_at_ms': enqueuedAt,
      'updated_at_ms': enqueuedAt,
    });
    await legacy.close();

    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final db = await database.database;
    final slaRows = await db.query('sla_fallbacks');
    expect(slaRows, hasLength(1));
    expect(slaRows.single['message_id'], 'existing-message');
    expect(slaRows.single['due_at_ms'], enqueuedAt + 20000);
    expect(slaRows.single['state'], 'pending');

    final columns = await db.rawQuery('PRAGMA table_info(generated_drafts)');
    final names = columns.map((row) => row['name']).toSet();
    expect(
        names,
        containsAll(<String>{
          'delivery_state',
          'delivery_attempts',
          'retry_at_ms',
          'last_error',
        }));
  });

  test('version 10 migration restores pending fallback to 20 seconds',
      () async {
    final root =
        await Directory.systemTemp.createTemp('sla_v10_migration_test_');
    final path = '${root.path}/jd_automation.sqlite3';
    sqfliteFfiInit();
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 9,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE sla_fallbacks (
            user_id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            due_at_ms INTEGER NOT NULL,
            state TEXT NOT NULL,
            sent_at_ms INTEGER,
            updated_at_ms INTEGER NOT NULL
          )''');
          await db.execute('''CREATE TABLE conversation_control (
            user_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            resume_after_message_id TEXT,
            updated_at_ms INTEGER NOT NULL
          )''');
        },
      ),
    );
    const anchor = 1800000000000;
    await legacy.insert('sla_fallbacks', {
      'user_id': 'waiting-v9',
      'message_id': 'message-v9',
      'due_at_ms': anchor + 35000,
      'state': 'pending',
      'sent_at_ms': null,
      'updated_at_ms': anchor,
    });
    await legacy.close();

    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final db = await database.database;
    final rows = await db.query('sla_fallbacks');
    expect(rows.single['due_at_ms'], anchor + 20000);
  });

  test('demo data uses JSON history and SQLite only as pending queue',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_automation_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    await database.seedDemoData();
    await database.seedDemoData();

    final pending = await database.conversations();
    expect(pending.map((item) => item.customerName),
        containsAll(<String>['tb302030', 'tb32020']));
    expect(pending, hasLength(2));

    final store = await database.history;
    final first = await store.read('tb302030');
    expect(first?['messages'], hasLength(1));
    final second = await store.read('tb32020');
    final secondMessages = second?['messages'] as List<Object?>;
    final media = (secondMessages.single as Map<String, dynamic>)['media']
        as List<Object?>;
    final mediaPath = (media.single as Map<String, dynamic>)['path'] as String;
    expect(await File(mediaPath).exists(), isTrue);
    expect(
        await store.updateMediaDescriptions(
            'tb32020', {mediaPath: 'A one-pixel demo customer image.'}),
        1);
    final described = await store.read('tb32020');
    final describedMessages = described?['messages'] as List<Object?>;
    final describedMedia = (describedMessages.single
        as Map<String, dynamic>)['media'] as List<Object?>;
    expect((describedMedia.single as Map<String, dynamic>)['description'],
        'A one-pixel demo customer image.');
    expect(
        await store.hasSimilarImageFingerprint('tb32020', 'fffffffffffffffe'),
        isTrue);
    expect(
        await store.hasSimilarImageFingerprint('tb32020', 'fffffffffffffffe',
            captureSources: const {'verified_window_crop'}),
        isFalse);
    expect(
        await store.hasSimilarImageFingerprint('tb32020', '0000000000000000'),
        isFalse);

    const rawReply =
        '{"reply":"Hello! How can I help?","decision":"draft","confidence":0.9,"risk_level":"low","model":"demo-codex","used_record_ids":[],"actions":[],"attachments":[]}';
    final draft = AiDraft(
      reply: 'Hello! How can I help?',
      decision: 'draft',
      confidence: 0.9,
      riskLevel: 'low',
      model: 'demo-codex',
      usedRecordIds: const [],
      actions: const [],
      attachments: const [],
      rawJson: rawReply,
    );
    await database.saveDraft(pending.first.id, draft);

    expect(await database.conversations(), hasLength(1));
    final beforeSend = await store.read(pending.first.customerName);
    expect(beforeSend?['messages'], hasLength(1));

    expect(
        await database.markReplySent(
            userId: pending.first.customerName, reply: draft.reply),
        isTrue);
    final completed = await store.read(pending.first.customerName);
    final completedMessages = completed?['messages'] as List<Object?>;
    expect(completedMessages, hasLength(2));
    expect((completedMessages.last as Map<String, dynamic>)['body'],
        'Hello! How can I help?');
    expect((completedMessages.last as Map<String, dynamic>)['delivery_status'],
        'sent');
  });

  test('ready replies can be delivered while another customer generates',
      () async {
    final root = await Directory.systemTemp.createTemp('fifo_delivery_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    CapturedConversation capture(String user, int sequence) =>
        CapturedConversation(
          stableKey: 'customer:$user',
          customerName: user,
          customerExternalId: user,
          capturedAt: DateTime.fromMillisecondsSinceEpoch(sequence),
          messages: [
            CapturedMessage(
              stableId: '$user-message',
              direction: 'incoming',
              body: 'Message from $user',
              axPath: 'test',
            ),
          ],
        );

    AiDraft draft(String user) => AiDraft(
          reply: 'Reply to $user',
          decision: 'draft',
          confidence: 1,
          riskLevel: 'low',
          model: 'test',
          usedRecordIds: const [],
          actions: const [],
          attachments: const [],
          rawJson:
              '{"reply":"Reply to $user","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}',
        );

    await database.saveCapture(capture('customer-a', 1));
    await database.saveCapture(capture('customer-b', 2));
    final pending = await database.conversations();
    final first = pending.firstWhere((item) => item.userId == 'customer-a');
    final second = pending.firstWhere((item) => item.userId == 'customer-b');

    // B finishes first, so its ready reply does not wait for A's generation.
    await database.saveDraft(second.id, draft('customer-b'));
    expect((await database.nextReadyDelivery())?.userId, 'customer-b');

    await database.saveDraft(first.id, draft('customer-a'));
    final deliveryA = await database.nextReadyDelivery();
    expect(deliveryA?.userId, 'customer-a');
    await database.markReplySent(
        userId: deliveryA!.userId, reply: deliveryA.draft.reply);

    final deliveryB = await database.nextReadyDelivery();
    expect(deliveryB?.userId, 'customer-b');
  });

  test('a pending generation does not block a ready reply', () async {
    final root = await Directory.systemTemp.createTemp('fifo_failure_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    CapturedConversation capture(String user, int sequence) =>
        CapturedConversation(
          stableKey: 'customer:$user',
          customerName: user,
          customerExternalId: user,
          capturedAt: DateTime.fromMillisecondsSinceEpoch(sequence),
          messages: [
            CapturedMessage(
                stableId: '$user-message',
                direction: 'incoming',
                body: user,
                axPath: 'test'),
          ],
        );
    const secondDraft = AiDraft(
      reply: 'Reply B',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson:
          '{"reply":"Reply B","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}',
    );

    await database.saveCapture(capture('customer-a', 1));
    await database.saveCapture(capture('customer-b', 2));
    final pending = await database.conversations();
    final second = pending.firstWhere((item) => item.userId == 'customer-b');
    await database.saveDraft(second.id, secondDraft);
    expect((await database.nextReadyDelivery())?.userId, 'customer-b');

    await database.abandonPendingCustomer('customer-a');
    expect((await database.nextReadyDelivery())?.userId, 'customer-b');
  });

  test('pending message identity changes when a later burst line arrives',
      () async {
    final root = await Directory.systemTemp.createTemp('burst_guard_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    CapturedConversation capture(String id, String body, int time) =>
        CapturedConversation(
          stableKey: 'customer:burst',
          customerName: 'burst',
          customerExternalId: 'burst',
          capturedAt: DateTime.fromMillisecondsSinceEpoch(time),
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: body,
                axPath: 'test'),
          ],
        );

    await database.saveCapture(capture('line-1', 'android', 1));
    expect(await database.pendingMessageId('burst'), 'line-1');

    await database.saveCapture(capture('line-2', 'over wifi', 2));
    expect(await database.pendingMessageId('burst'), 'line-2');
  });

  test('frozen image batch can be sent while later text stays pending',
      () async {
    final root = await Directory.systemTemp.createTemp('image_text_batch_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    CapturedConversation capture(CapturedMessage message, int time) =>
        CapturedConversation(
          stableKey: 'customer:buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: DateTime.fromMillisecondsSinceEpoch(time),
          messages: [message],
        );
    await database.saveCapture(capture(
        const CapturedMessage(
          stableId: 'image-1',
          direction: 'incoming',
          body: '[Customer sent an image]',
          axPath: 'test',
          media: [CapturedMedia(type: 'image', path: '/tmp/customer.png')],
        ),
        1));
    final pending = (await database.conversations()).single;
    // OCR sees the new text and the already saved image in one viewport.
    // The old image is last in this capture list, but must not rewind pending.
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(2),
      messages: const [
        CapturedMessage(
          stableId: 'text-2',
          direction: 'incoming',
          body: 'What is this error?',
          axPath: 'test',
        ),
        CapturedMessage(
          stableId: 'image-1',
          direction: 'incoming',
          body: '[Customer sent an image]',
          axPath: 'test',
          media: [CapturedMedia(type: 'image', path: '/tmp/customer.png')],
        ),
      ],
    ));
    const draft = AiDraft(
      reply: 'Old image-only answer',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson: '{"reply":"Old image-only answer","decision":"draft",'
          '"confidence":1,"risk_level":"low","model":"test",'
          '"used_record_ids":[],"actions":[],"attachments":[]}',
    );
    expect(
        await database.saveDraft(pending.id, draft,
            expectedMessageId: 'image-1'),
        1);
    expect(await database.pendingMessageId('buyer'), 'text-2');
    expect(await database.hasUndeliveredDraft('buyer'), isTrue);
    expect((await database.nextReadyDelivery())?.draft.reply,
        'Old image-only answer');
    final sentAtLowerBound = DateTime.now();
    expect(await database.markReplySent(userId: 'buyer', reply: draft.reply),
        isTrue);
    final sentAtUpperBound = DateTime.now();
    expect(await database.answeredMessageId('buyer'), 'image-1');
    expect(await database.hasPendingUnanswered('buyer'), isTrue);
    final remainingFallback = await database.slaFallbackJob('buyer');
    expect(remainingFallback?.messageId, 'text-2');
    expect(
      remainingFallback!.dueAt.millisecondsSinceEpoch,
      inInclusiveRange(
        sentAtLowerBound
            .add(const Duration(seconds: 20))
            .millisecondsSinceEpoch,
        sentAtUpperBound
            .add(const Duration(seconds: 20))
            .millisecondsSinceEpoch,
      ),
    );
    final messages = ((await (await database.history)
            .read('buyer'))?['messages'] as List<Object?>? ??
        const []);
    expect(messages.map((message) => (message as Map<String, dynamic>)['id']),
        containsAll(['image-1', 'text-2']));
  });

  test('automatic transfer preserves the existing human-contacting boundary',
      () async {
    final root = await Directory.systemTemp.createTemp('ticket_state_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final first = CapturedConversation(
      stableKey: 'customer:test-buyer',
      customerName: 'test-buyer',
      customerExternalId: 'test-buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(1),
      messages: const [
        CapturedMessage(
            stableId: 'message-1',
            direction: 'incoming',
            body: 'I want a refund',
            axPath: 'ocr'),
      ],
    );
    await database.saveCapture(first);
    final ticket = await database.createHumanReviewTicket(
        userId: 'test-buyer',
        customerRequest: 'I want a refund',
        reason: 'Customer explicitly requested human assistance.',
        requestMessageId: 'message-1');
    expect(ticket.status, 'open');
    expect(await database.isHumanContacting('test-buyer'), isFalse);
    expect(await database.hasPendingUnanswered('test-buyer'), isTrue);

    // An open review ticket remains informational until transfer starts.
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:test-buyer',
      customerName: 'test-buyer',
      customerExternalId: 'test-buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(2),
      messages: const [
        CapturedMessage(
            stableId: 'open-ticket-follow-up',
            direction: 'incoming',
            body: 'This clarifies the same request',
            axPath: 'ocr'),
      ],
    ));
    expect((await database.conversations()).single.userId, 'test-buyer');

    await database.markTicketContacting(ticket.id);
    expect(await database.isHumanContacting('test-buyer'), isTrue);
    expect(await database.conversations(), isEmpty);

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:test-buyer',
      customerName: 'test-buyer',
      customerExternalId: 'test-buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(3),
      messages: const [
        CapturedMessage(
            stableId: 'message-2',
            direction: 'incoming',
            body: 'Human-handled message',
            axPath: 'ocr'),
      ],
    ));
    expect(await database.conversations(), isEmpty);

    // The manual seller response is captured while human control is active.
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:test-buyer',
      customerName: 'test-buyer',
      customerExternalId: 'test-buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(4),
      messages: const [
        CapturedMessage(
            stableId: 'manual-reply-1',
            direction: 'outgoing',
            body: 'A human handled this question.',
            axPath: 'ocr'),
      ],
    ));
    expect(await database.conversations(), isEmpty);

    // A takeover for one customer must not pause another customer's queue.
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:other-buyer',
      customerName: 'other-buyer',
      customerExternalId: 'other-buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(4),
      messages: const [
        CapturedMessage(
            stableId: 'other-message-1',
            direction: 'incoming',
            body: 'What is the portable printer price?',
            axPath: 'ocr'),
      ],
    ));
    expect((await database.conversations()).single.userId, 'other-buyer');

    await database.markTicketContacted(
      ticket.id,
      assignedTo: '格志打印机小秦',
    );
    expect(await database.humanReviewTickets(), isEmpty);
    final transferredTicket = await (await database.database).query(
      'human_review_tickets',
      columns: ['status', 'assigned_to'],
      where: 'id = ?',
      whereArgs: [ticket.id],
      limit: 1,
    );
    expect(transferredTicket.single['status'], 'contacted');
    expect(transferredTicket.single['assigned_to'], '格志打印机小秦');
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:test-buyer',
      customerName: 'test-buyer',
      customerExternalId: 'test-buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(5),
      messages: const [
        CapturedMessage(
            stableId: 'message-3',
            direction: 'incoming',
            body: 'A genuinely new question',
            axPath: 'ocr'),
      ],
    ));
    expect((await database.conversations()).map((item) => item.userId),
        containsAll(<String>['other-buyer', 'test-buyer']));
  });

  test('records one automatic transfer per ticket and rotates active accounts',
      () async {
    final root = await Directory.systemTemp.createTemp('transfer_log_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    final first = await database.createHumanReviewTicket(
      userId: 'buyer-1',
      customerRequest: 'Please help',
      reason: 'Technical review required',
    );
    expect(await database.reserveChatTransferLog(ticket: first), isNull);
    final explicitFirst = await database.createHumanReviewTicket(
      userId: 'buyer-1',
      customerRequest: 'No, please transfer me',
      reason: 'Customer explicitly requested human assistance.',
      requestMessageId: 'buyer-1-second-transfer-request',
    );
    final firstLog =
        await database.reserveChatTransferLog(ticket: explicitFirst);
    expect(firstLog, isNotNull);
    expect(
        await database.reserveChatTransferLog(ticket: explicitFirst), isNull);

    final firstTarget = await database.chooseAutomaticTransferAccount(
      const ['格志打印机小雨', '格志打印机小秦'],
    );
    expect(firstTarget, '格志打印机小秦');
    await database.updateChatTransferLog(
      id: firstLog!.id,
      status: 'transferred',
      sourceAccount: '格志打印机小甘',
      targetAccount: firstTarget,
    );

    final second = await database.createHumanReviewTicket(
      userId: 'buyer-2',
      customerRequest: 'Please help too',
      reason: 'Warranty review required',
      requestMessageId: 'buyer-2-original-review',
    );
    final secondLog = await database.reserveChatTransferLog(ticket: second);
    final secondTarget = await database.chooseAutomaticTransferAccount(
      const ['格志打印机小雨', '格志打印机小秦'],
    );
    expect(secondTarget, '格志打印机小雨');
    await database.updateChatTransferLog(
      id: secondLog!.id,
      status: 'failed',
      sourceAccount: '格志打印机小甘',
      targetAccount: secondTarget,
      error: 'JD dialog closed',
    );

    final logs = await database.chatTransferLogs();
    expect(logs, hasLength(2));
    expect(logs.first.sourceAccount, '格志打印机小甘');
    expect(logs.first.targetAccount, '格志打印机小雨');
    expect(logs.first.reason, 'Warranty review required');
    expect(logs.first.status, 'failed');
    expect(logs.first.error, 'JD dialog closed');

    expect(await database.reserveChatTransferLog(ticket: second), isNull);
    final retryTicket = await database.createHumanReviewTicket(
      userId: 'buyer-2',
      customerRequest: 'Please help again',
      reason: 'New warranty review request',
      requestMessageId: 'buyer-2-new-review',
    );
    final retried = await database.reserveChatTransferLog(ticket: retryTicket);
    expect(retried, isNotNull);
    expect(retried!.id, secondLog.id);
    expect(retried.status, 'pending');
    expect(retried.targetAccount, isNull);
    expect(retried.error, isNull);
    expect(await database.reserveChatTransferLog(ticket: second), isNull);
  });

  test('pre-click transfer failure restores capture and current-account AI',
      () async {
    final root =
        await Directory.systemTemp.createTemp('transfer_capture_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:failed-transfer',
      customerName: 'failed-transfer',
      customerExternalId: 'failed-transfer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(1),
      messages: const [
        CapturedMessage(
          stableId: 'before-transfer',
          direction: 'incoming',
          body: 'Please transfer me',
          axPath: 'ocr',
        ),
      ],
    ));
    final ticket = await database.createHumanReviewTicket(
      userId: 'failed-transfer',
      customerRequest: 'Please transfer me',
      reason: 'Customer requested another agent',
      requestMessageId: 'before-transfer',
    );
    expect(await database.isHumanContacting('failed-transfer'), isFalse);

    await database.markTicketContacting(ticket.id);
    expect(await database.isHumanContacting('failed-transfer'), isTrue);

    await database.markTicketAwaitingCurrentAgent(ticket.id);
    expect(await database.isHumanContacting('failed-transfer'), isFalse);

    final inserted = await database.saveCapture(CapturedConversation(
      stableKey: 'customer:failed-transfer',
      customerName: 'failed-transfer',
      customerExternalId: 'failed-transfer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(2),
      messages: const [
        CapturedMessage(
          stableId: 'after-failure',
          direction: 'incoming',
          body: 'This message must still reload',
          axPath: 'ocr',
        ),
      ],
    ));
    expect(inserted, 1);
    expect(await database.hasPendingUnanswered('failed-transfer'), isTrue);
    expect((await database.conversations()).single.userId, 'failed-transfer');
    final document = await database.history.then(
      (history) => history.read('failed-transfer'),
    );
    final messages = (document!['messages'] as List<Object?>)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    expect(messages.last['body'], 'This message must still reload');
    expect((await database.humanReviewTickets()).single.status, 'open');
  });

  test('human-contacting pause remains until the operator resolves it',
      () async {
    final root = await Directory.systemTemp.createTemp('legacy_pause_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    final db = await database.database;
    await db.insert('conversation_control', {
      'user_id': 'legacy-paused-buyer',
      'state': 'human_contacting',
      'resume_after_message_id': null,
      'updated_at_ms': 1,
    });

    expect(
      await database.saveCapture(CapturedConversation(
        stableKey: 'customer:legacy-paused-buyer',
        customerName: 'legacy-paused-buyer',
        customerExternalId: 'legacy-paused-buyer',
        capturedAt: DateTime.fromMillisecondsSinceEpoch(2),
        messages: const [
          CapturedMessage(
            stableId: 'first-message-after-old-transfer',
            direction: 'incoming',
            body: 'Please answer this message',
            axPath: 'ocr',
          ),
        ],
      )),
      1,
    );
    expect(await database.isHumanContacting('legacy-paused-buyer'), isTrue);
    expect(await database.hasPendingUnanswered('legacy-paused-buyer'), isFalse);
    expect(await database.conversations(), isEmpty);
  });

  test('unconfirmed transfer also preserves future automatic replies',
      () async {
    final root = await Directory.systemTemp.createTemp('uncertain_transfer_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final ticket = await database.createHumanReviewTicket(
      userId: 'uncertain-transfer',
      customerRequest: 'Please transfer me',
      reason: 'Customer requested another agent',
    );
    await database.markTicketAwaitingCurrentAgent(ticket.id);
    expect(await database.isHumanContacting('uncertain-transfer'), isFalse);
    expect(
      await database.saveCapture(CapturedConversation(
        stableKey: 'customer:uncertain-transfer',
        customerName: 'uncertain-transfer',
        customerExternalId: 'uncertain-transfer',
        capturedAt: DateTime.fromMillisecondsSinceEpoch(3),
        messages: const [
          CapturedMessage(
            stableId: 'after-uncertain-click',
            direction: 'incoming',
            body: 'Can anyone see this?',
            axPath: 'ocr',
          ),
        ],
      )),
      1,
    );
    expect(await database.hasPendingUnanswered('uncertain-transfer'), isTrue);
    expect(
      (await database.conversations()).single.userId,
      'uncertain-transfer',
    );
  });

  test('deduplicates a recently re-ordered OCR reading of one message',
      () async {
    final root = await Directory.systemTemp.createTemp('ocr_reorder_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final firstTime = DateTime.utc(2026, 8, 30, 5, 58, 41);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: firstTime,
      messages: const [
        CapturedMessage(
          stableId: 'ocr:first',
          direction: 'incoming',
          body: 'sorry it was slip of pen. typing',
          axPath: 'ocr',
        ),
      ],
    ));
    final pending = (await database.conversations()).single;
    const replyJson =
        '{"reply":"No worries.","decision":"draft","confidence":0.99,'
        '"risk_level":"low","model":"gpt-5.6-sol","used_record_ids":[],'
        '"actions":[],"attachments":[]}';
    await database.saveDraft(
      pending.id,
      const AiDraft(
        reply: 'No worries.',
        decision: 'draft',
        confidence: 0.99,
        riskLevel: 'low',
        model: 'gpt-5.6-sol',
        usedRecordIds: [],
        actions: [],
        attachments: [],
        rawJson: replyJson,
      ),
    );
    await database.markReplySent(userId: 'buyer', reply: 'No worries.');

    final changed = await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: firstTime.add(const Duration(seconds: 15)),
      messages: const [
        CapturedMessage(
          stableId: 'ocr:reordered',
          direction: 'incoming',
          body: 'slip of pen. typing sorry it was',
          axPath: 'ocr',
        ),
      ],
    ));

    expect(changed, 0);
    expect(await database.hasPendingUnanswered('buyer'), isFalse);
    final document = await (await database.history).read('buyer');
    expect(document?['messages'], hasLength(2));
  });

  test('deduplicates an OCR spelling correction at the same bubble time',
      () async {
    final root = await Directory.systemTemp.createTemp('ocr_typo_fix_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final bubbleTime = DateTime.utc(2026, 9, 21, 4, 38, 54);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: bubbleTime,
      messages: [
        CapturedMessage(
          stableId: 'ocr:misspelled',
          direction: 'incoming',
          body: 'please transter',
          sentAt: bubbleTime,
          axPath: 'ocr',
        ),
      ],
    ));
    final pending = (await database.conversations()).single;
    const draft = AiDraft(
      reply: 'I have noted your request.',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson:
          '{"reply":"I have noted your request.","decision":"draft","confidence":1,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}',
    );
    await database.saveDraft(pending.id, draft,
        expectedMessageId: 'ocr:misspelled');
    await database.markReplySent(userId: 'buyer', reply: draft.reply);

    final changed = await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: bubbleTime.add(const Duration(seconds: 14)),
      messages: [
        CapturedMessage(
          stableId: 'ocr:corrected',
          direction: 'incoming',
          body: 'please transfer',
          sentAt: bubbleTime,
          axPath: 'ocr',
        ),
      ],
    ));

    expect(changed, 0);
    expect(await database.hasPendingUnanswered('buyer'), isFalse);
    expect(await database.slaFallbackJob('buyer'), isNull);
  });

  test('upgrades a clipped incoming bubble without replying twice', () async {
    final root = await Directory.systemTemp.createTemp('ocr_upgrade_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final firstTime = DateTime.utc(2026, 8, 31, 8, 35, 47);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: firstTime,
      messages: const [
        CapturedMessage(
          stableId: 'ocr:partial',
          direction: 'incoming',
          body: 'what is the model no of your face',
          axPath: 'ocr',
        ),
      ],
    ));
    final pending = (await database.conversations()).single;
    const replyJson =
        '{"reply":"Let me help.","decision":"draft","confidence":0.9,'
        '"risk_level":"low","model":"test","used_record_ids":[],'
        '"actions":[],"attachments":[]}';
    await database.saveDraft(
        pending.id,
        const AiDraft(
            reply: 'Let me help.',
            decision: 'draft',
            confidence: 0.9,
            riskLevel: 'low',
            model: 'test',
            usedRecordIds: [],
            actions: [],
            attachments: [],
            rawJson: replyJson));
    await database.markReplySent(userId: 'buyer', reply: 'Let me help.');

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: firstTime.add(const Duration(seconds: 15)),
      messages: const [
        CapturedMessage(
          stableId: 'ocr:complete',
          direction: 'incoming',
          body: 'what is the model no of your face attendance machine?',
          axPath: 'ocr',
        ),
      ],
    ));

    expect(await database.hasPendingUnanswered('buyer'), isFalse);
    final document = await (await database.history).read('buyer');
    final messages = document!['messages'] as List<Object?>;
    expect(messages, hasLength(2));
    expect((messages.first as Map<String, dynamic>)['body'],
        'what is the model no of your face attendance machine?');
  });

  test('suppresses a middle fragment of an already sent reply', () async {
    final root = await Directory.systemTemp.createTemp('ocr_reply_fragment_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(1),
      messages: const [
        CapturedMessage(
          stableId: 'incoming',
          direction: 'incoming',
          body: 'Are you a real person?',
          axPath: 'ocr',
        ),
      ],
    ));
    final pending = (await database.conversations()).single;
    const fullReply =
        "I'm a virtual customer-service assistant, so I don't have a real face.";
    const replyJson =
        '{"reply":"I\u0027m a virtual customer-service assistant, so I don\u0027t have a real face.","decision":"draft","confidence":0.9,'
        '"risk_level":"low","model":"test","used_record_ids":[],'
        '"actions":[],"attachments":[]}';
    await database.saveDraft(
        pending.id,
        const AiDraft(
            reply: fullReply,
            decision: 'draft',
            confidence: 0.9,
            riskLevel: 'low',
            model: 'test',
            usedRecordIds: [],
            actions: [],
            attachments: [],
            rawJson: replyJson));
    await database.markReplySent(userId: 'buyer', reply: fullReply);

    final changed = await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(2),
      messages: const [
        CapturedMessage(
          stableId: 'outgoing-fragment',
          direction: 'outgoing',
          body: 'virtual customer-service assistant',
          axPath: 'ocr',
        ),
      ],
    ));

    expect(changed, 0);
    final document = await (await database.history).read('buyer');
    expect(document!['messages'], hasLength(2));
  });

  test('requeues an unanswered saved message but not an answered one',
      () async {
    final root = await Directory.systemTemp.createTemp('draft_recovery_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final capture = CapturedConversation(
      stableKey: 'customer:recovery',
      customerName: 'recovery-user',
      customerExternalId: 'recovery-user',
      capturedAt: DateTime.now(),
      messages: const [
        CapturedMessage(
          stableId: 'recovery-message-1',
          direction: 'incoming',
          body: 'Need help',
          axPath: 'test',
        ),
      ],
    );
    await database.saveCapture(capture);
    await (await database.database).delete('pending_customers',
        where: 'user_id = ?', whereArgs: ['recovery-user']);

    expect(await database.ensurePendingForUnanswered('recovery-user'), isTrue);
    final pending = await database.conversations();
    final conversation =
        pending.singleWhere((item) => item.userId == 'recovery-user');
    const draft = AiDraft(
      reply: 'How can I help?',
      decision: 'draft',
      confidence: 0.9,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson: '{"reply":"How can I help?"}',
    );
    await database.saveDraft(conversation.id, draft);

    expect(await database.ensurePendingForUnanswered('recovery-user'), isFalse);
  });

  test('repairs a missing pending turn with an orphaned OCR cursor', () async {
    final root = await Directory.systemTemp.createTemp('orphan_cursor_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final now = DateTime.now();
    Future<void> capture(String id, String body, DateTime at) => database
        .saveCapture(CapturedConversation(
          stableKey: 'customer:buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at,
          messages: [
            CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: body,
              sentAt: at,
              axPath: 'test',
            )
          ],
        ))
        .then((_) {});
    await capture('old', 'M880UT question', now);
    final oldPending = (await database.conversations()).single;
    const draft = AiDraft(
      reply: 'Earlier answer',
      decision: 'draft',
      confidence: 1,
      riskLevel: 'low',
      model: 'test',
      usedRecordIds: [],
      actions: [],
      attachments: [],
      rawJson: '{"reply":"Earlier answer"}',
    );
    await database.saveDraft(oldPending.id, draft, expectedMessageId: 'old');
    await database.markReplySent(userId: 'buyer', reply: draft.reply);
    await (await database.database).update(
      'answered_cursors',
      {'message_id': 'ocr-id-that-was-replaced'},
      where: 'user_id = ?',
      whereArgs: ['buyer'],
    );
    await capture('model', 'I have TP732', now.add(const Duration(seconds: 2)));
    await capture('question', 'How do I connect it to the app?',
        now.add(const Duration(seconds: 4)));
    await (await database.database).delete('pending_customers',
        where: 'user_id = ?', whereArgs: ['buyer']);

    expect(await database.ensurePendingForUnanswered('buyer'), isTrue);
    expect(await database.pendingMessageId('buyer'), 'question');
    expect(await database.hasPendingUnanswered('buyer'), isTrue);
  });

  test('a real reply starts a fresh fallback window after an old holding',
      () async {
    final root = await Directory.systemTemp.createTemp('new_sla_window_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final now = DateTime.now();
    CapturedConversation incoming(String id, DateTime at) =>
        CapturedConversation(
          stableKey: 'customer:buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at,
          messages: [
            CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: id,
              sentAt: at,
              axPath: 'test',
            )
          ],
        );
    await database.saveCapture(incoming('old-question', now));
    await (await database.database).update(
      'sla_fallbacks',
      {'state': 'sent', 'sent_at_ms': now.millisecondsSinceEpoch},
      where: 'user_id = ?',
      whereArgs: ['buyer'],
    );
    final history = await database.history;
    await history.appendSlaFallbackSent(
      userId: 'buyer',
      messageId: 'old-question',
      reply: '请稍等。',
    );
    await history.appendSentReply(
      userId: 'buyer',
      displayName: 'buyer',
      stableKey: 'customer:buyer',
      draft: const AiDraft(
        reply: 'Earlier answer',
        decision: 'draft',
        confidence: 1,
        riskLevel: 'low',
        model: 'test',
        usedRecordIds: [],
        actions: [],
        attachments: [],
        rawJson: '{"reply":"Earlier answer"}',
      ),
    );
    await database.saveCapture(
        incoming('new-question', now.add(const Duration(seconds: 30))));
    final job = await database.slaFallbackJob('buyer');
    expect(job?.messageId, 'new-question');
    expect(await database.hasPendingUnanswered('buyer'), isTrue);
  });

  test('seller reply clears pending customer and cannot trigger another draft',
      () async {
    final root = await Directory.systemTemp.createTemp('seller_reply_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final incoming = CapturedConversation(
      stableKey: 'customer:answered',
      customerName: 'answered-user',
      customerExternalId: 'answered-user',
      capturedAt: DateTime.fromMillisecondsSinceEpoch(1),
      messages: [
        CapturedMessage(
          stableId: 'incoming-1',
          direction: 'incoming',
          body: 'How can I buy this?',
          sentAt: DateTime.fromMillisecondsSinceEpoch(1),
          axPath: 'test',
        ),
      ],
    );
    await database.saveCapture(incoming);
    expect(await database.conversations(), hasLength(1));

    await database.saveCapture(CapturedConversation(
      stableKey: incoming.stableKey,
      customerName: incoming.customerName,
      customerExternalId: incoming.customerExternalId,
      capturedAt: DateTime.fromMillisecondsSinceEpoch(2),
      messages: [
        CapturedMessage(
          stableId: 'incoming-1',
          direction: 'incoming',
          body: 'How can I buy this?',
          sentAt: DateTime.fromMillisecondsSinceEpoch(1),
          axPath: 'test',
        ),
        CapturedMessage(
          stableId: 'outgoing-1',
          direction: 'outgoing',
          body: 'I will send the purchase link.',
          sentAt: DateTime.fromMillisecondsSinceEpoch(2),
          deliveryConfirmed: true,
          axPath: 'test',
        ),
      ],
    ));

    expect(await database.conversations(), isEmpty);
    expect(await database.ensurePendingForUnanswered('answered-user'), isFalse);

    // Simulate a stale queue row left by an older build. Eligibility checking
    // must repair it before Codex can run again.
    final db = await database.database;
    await db.insert('pending_customers', {
      'user_id': 'answered-user',
      'display_name': 'answered-user',
      'stable_key': 'customer:answered',
      'newest_message_id': 'incoming-1',
      'enqueued_at_ms': 1,
      'updated_at_ms': 2,
    });
    expect(await database.hasPendingUnanswered('answered-user'), isFalse);
    expect(await database.conversations(), isEmpty);
  });

  test('same JD timestamp suppresses partial OCR re-reads', () async {
    final root = await Directory.systemTemp.createTemp('bubble_time_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final sentAt = DateTime(2026, 8, 31, 18, 18, 16);
    CapturedConversation capture(String id, String body, DateTime capturedAt) =>
        CapturedConversation(
          stableKey: 'customer:timestamp',
          customerName: 'jd_test',
          customerExternalId: 'jd_test',
          capturedAt: capturedAt,
          messages: [
            CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: body,
              sentAt: sentAt,
              axPath: 'ocr:test',
            ),
          ],
        );

    await database
        .saveCapture(capture('ocr:first', 'not finding the machine', sentAt));
    await database.saveCapture(capture('ocr:partial', 'am not finding',
        sentAt.add(const Duration(seconds: 30))));

    final history = await database.history;
    final document = await history.read('jd_test');
    final messages = document!['messages'] as List<Object?>;
    expect(messages, hasLength(1));
    expect((messages.single as Map<String, dynamic>)['body'],
        'not finding the machine');
  });

  test('same customer text at a new timestamp is a new pending message',
      () async {
    final root = await Directory.systemTemp.createTemp('repeat_text_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final firstTime = DateTime.utc(2026, 9, 4, 5, 20, 5);
    CapturedConversation capture(String id, DateTime sentAt) =>
        CapturedConversation(
          stableKey: 'customer:repeat',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: sentAt.add(const Duration(seconds: 3)),
          messages: [
            CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: 'do i need to add ink on that thermal printer',
              sentAt: sentAt,
              axPath: 'ocr',
            ),
          ],
        );

    await database.saveCapture(capture('first-question', firstTime));
    final secondTime = firstTime.add(const Duration(seconds: 32));
    await database.saveCapture(capture('repeated-question', secondTime));

    expect(await database.pendingMessageId('buyer'), 'repeated-question');
    final document = await (await database.history).read('buyer');
    expect(document!['messages'], hasLength(2));
  });

  test(
      'known generated reply below a late-captured question does not answer it',
      () async {
    final root = await Directory.systemTemp.createTemp('crossed_reply_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final start = DateTime.utc(2026, 9, 4, 5, 19, 51);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:crossed',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: start,
      messages: [
        CapturedMessage(
          stableId: 'try-message',
          direction: 'incoming',
          body: 'ok.. i will try',
          sentAt: start,
          axPath: 'ocr',
        ),
      ],
    ));
    final pending = (await database.conversations()).single;
    const reply =
        'Okay, please try it. If the paper still jams, let us know what happens.';
    await database.saveDraft(
        pending.id,
        const AiDraft(
          reply: reply,
          decision: 'draft',
          confidence: .99,
          riskLevel: 'low',
          model: 'test',
          usedRecordIds: [],
          actions: [],
          attachments: [],
          rawJson:
              '{"reply":"Okay, please try it. If the paper still jams, let us know what happens.","decision":"draft","confidence":0.99,"risk_level":"low","model":"test","used_record_ids":[],"actions":[],"attachments":[]}',
        ));
    await database.markReplySent(userId: 'buyer', reply: reply);

    final questionTime = start.add(const Duration(seconds: 14));
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:crossed',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: questionTime.add(const Duration(seconds: 5)),
      messages: [
        CapturedMessage(
          stableId: 'ink-question',
          direction: 'incoming',
          body: 'do i need to add ink on that thermal printer',
          sentAt: questionTime,
          axPath: 'ocr',
        ),
        CapturedMessage(
          stableId: 'visible-known-reply',
          direction: 'outgoing',
          body: reply,
          sentAt: questionTime.add(const Duration(seconds: 2)),
          axPath: 'ocr',
        ),
      ],
    ));

    expect(await database.pendingMessageId('buyer'), 'ink-question');
  });

  test('older seller OCR above a newer customer message keeps AI pending',
      () async {
    final root = await Directory.systemTemp.createTemp('ordered_scan_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final now = DateTime.utc(2026, 9, 4, 6, 25, 25);

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:ordered',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: now,
      messages: [
        CapturedMessage(
          stableId: 'older-seller-ocr',
          direction: 'outgoing',
          body: 'A previously visible seller message',
          sentAt: now.subtract(const Duration(seconds: 39)),
          axPath: 'ocr',
        ),
        CapturedMessage(
          stableId: 'new-customer-question',
          direction: 'incoming',
          body: "isn't it your product?",
          sentAt: now.subtract(const Duration(seconds: 5)),
          axPath: 'ocr',
        ),
      ],
    ));

    expect(await database.pendingMessageId('buyer'), 'new-customer-question');
  });

  test('older seller OCR appended after a newer customer stays pending',
      () async {
    final root = await Directory.systemTemp.createTemp('late_old_reply_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final now = DateTime.utc(2026, 9, 19, 6, 30);

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:late-old-reply',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: now,
      messages: [
        CapturedMessage(
          stableId: 'new-customer-message',
          direction: 'incoming',
          body: 'I still have a question.',
          sentAt: now.subtract(const Duration(minutes: 1)),
          axPath: 'ocr',
        ),
        CapturedMessage(
          stableId: 'older-seller-message',
          direction: 'outgoing',
          body: 'This seller reply belongs to yesterday.',
          sentAt: now.subtract(const Duration(days: 1)),
          axPath: 'ocr',
        ),
      ],
    ));

    expect(await database.pendingMessageId('buyer'), 'new-customer-message');
    expect(await database.hasPendingUnanswered('buyer'), isTrue);
    expect(await database.answeredMessageId('buyer'), isNull);
  });

  test('exact production sequence keeps one incoming and one outgoing',
      () async {
    final root =
        await Directory.systemTemp.createTemp('exact_jd_sequence_test_');
    final database = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final history = await database.history;
    final incomingTime = DateTime(2026, 8, 31, 18, 18, 16);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:exact',
      customerName: 'jd_41aeec7741d05',
      customerExternalId: 'jd_41aeec7741d05',
      capturedAt: incomingTime,
      messages: [
        CapturedMessage(
          stableId: 'ocr:original',
          direction: 'incoming',
          body: 'not finding the machine',
          sender: 'jd_41aeec7741d05',
          sentAt: incomingTime,
          axPath: 'ocr:test',
        ),
      ],
    ));
    const reply =
        'Please make sure your phone’s Bluetooth and location are turned on and that the app has permission to use both, then search again.';
    await history.appendSentReply(
      userId: 'jd_41aeec7741d05',
      displayName: 'jd_41aeec7741d05',
      stableKey: 'customer:exact',
      draft: const AiDraft(
        reply: reply,
        decision: 'ask_clarification',
        confidence: .97,
        riskLevel: 'medium',
        model: 'gpt-5.6-sol',
        usedRecordIds: [],
        actions: [],
        attachments: [],
        rawJson:
            '{"reply":"test","decision":"ask_clarification","confidence":0.97,"risk_level":"medium","model":"gpt-5.6-sol","used_record_ids":[],"actions":[],"attachments":[]}',
      ),
    );
    final documentBefore = await history.read('jd_41aeec7741d05');
    final generated = (documentBefore!['messages'] as List<Object?>)
        .whereType<Map<String, dynamic>>()
        .last;
    final generatedTime = DateTime.parse(generated['sent_at'] as String);

    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:exact',
      customerName: 'jd_41aeec7741d05',
      customerExternalId: 'jd_41aeec7741d05',
      capturedAt: generatedTime.add(const Duration(seconds: 15)),
      messages: [
        CapturedMessage(
          stableId: 'ocr:partial-incoming',
          direction: 'incoming',
          body: 'am not finding',
          sender: 'jd_41aeec7741d05',
          sentAt: incomingTime,
          axPath: 'ocr:test',
        ),
        CapturedMessage(
          stableId: 'ocr:partial-outgoing',
          direction: 'outgoing',
          body: "Please make sure your phone's",
          sender: '18:18:31 格志打印机小甘',
          sentAt: generatedTime.subtract(const Duration(seconds: 1)),
          axPath: 'ocr:test',
        ),
      ],
    ));

    final document = await history.read('jd_41aeec7741d05');
    final messages = document!['messages'] as List<Object?>;
    expect(messages, hasLength(2));
    expect((messages.first as Map<String, dynamic>)['body'],
        'not finding the machine');
    expect((messages.last as Map<String, dynamic>)['body'], reply);
  });
}
