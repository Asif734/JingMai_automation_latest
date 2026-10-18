import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_codex_session.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a failed newest video is not answered using older video contents',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_unreadable_new_video_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final at = DateTime.utc(2026, 10, 16, 3, 48, 4);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: at.add(const Duration(seconds: 40)),
      messages: [
        CapturedMessage(
            stableId: 'question-new-video',
            direction: 'incoming',
            body: 'what is in the video?',
            sentAt: at.add(const Duration(seconds: 40)),
            axPath: 'test')
      ],
    ));
    await (await database.history).recordMediaCaptureFailure('buyer', 'video',
        sentAt: at, reason: 'video_message_reference_unavailable');
    final service = CodexReplyService(
        executable: '/must-not-invoke-old-video-context',
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/reply.schema.json'));
    final draft = await service.generate(
        conversation: (await database.conversations()).single,
        database: database);
    expect(draft.model, 'jd-media-read-recovery-v1');
    expect(draft.reply, contains('haven’t been able to read its contents'));
    expect(draft.reply, isNot(contains('self-test')));
    expect(draftRequiresHumanReview(draft), isFalse);
  });

  test('a new media event routes reused photos and video to separate stages',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_resent_media_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    final store = await database.history;
    final photo = File(await store.saveMedia(
        userId: 'buyer', filename: 'reused-photo.png', bytes: [1, 2, 3]));
    final frame = File(await store.saveMedia(
        userId: 'buyer', filename: 'reused-video-frame.jpg', bytes: [4, 5, 6]));
    final argsLog = File('${root.path}/args.log');
    final promptLog = File('${root.path}/prompt.log');
    final fake = File('${root.path}/fake-codex.sh');
    await fake.writeAsString('''#!/bin/sh
printf '%s\\n' "\$*" >> "${argsLog.path}"
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat > "${promptLog.path}"
printf '%s\\n' '{"reply":"What happens when you press the button?","decision":"ask_clarification","confidence":0.9,"used_record_ids":[],"required_slots":["observed behavior"],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
printf '%s\\n' '{"type":"thread.started","thread_id":"resent-media-thread"}'
''');
    expect((await Process.run('chmod', ['+x', fake.path])).exitCode, 0);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.utc(2026, 10, 16, 3, 26, 16),
      messages: [
        CapturedMessage(
          stableId: 'visible-video:reused:1792121167',
          direction: 'incoming',
          body: '[Customer sent a video]',
          sentAt: DateTime.utc(2026, 10, 16, 3, 26, 7),
          axPath: 'test',
          media: [
            CapturedMedia(
                type: 'image',
                path: photo.path,
                description: 'Previous photo analysis.'),
            CapturedMedia(
                type: 'image',
                path: frame.path,
                description: 'Previous video analysis.',
                captureSource: 'jd_video_frame_1fps'),
          ],
        )
      ],
    ));
    final service = CodexReplyService(
        executable: fake.path,
        workspace: workspace,
        knowledgeDirectory: knowledge,
        outputSchema: File('${root.path}/reply.schema.json'));
    await service.generate(
        conversation: (await database.conversations()).single,
        database: database);
    final arguments = await argsLog.readAsLines();
    expect(arguments.first, contains(frame.path));
    expect(arguments.first, contains('video-report.schema.json'));
    expect(arguments.last, contains(photo.path));
    expect(arguments.last, isNot(contains(frame.path)));
    final prompt = await promptLog.readAsString();
    final request = jsonDecode(
            prompt.split('<request_json>\n')[1].split('\n</request_json>')[0])
        as Map<String, dynamic>;
    expect(request['image_analysis_required'], isTrue);
    expect(prompt, contains('Follow AGENTS.md.'));
    final requirements = (request['requirements'] as List).join('\n');
    expect(requirements.length, lessThan(4000));
    expect(requirements, contains('General/sales: if no answer is found'));
    expect(requirements, contains('keep events separate'));
    // Stable safety rules live once in AGENTS.md, not in every request too.
    final policy = await File('codex_workspace/AGENTS.md').readAsString();
    expect(policy, contains('D E'));
    expect(policy, contains('complete absolute URL'));
    expect(policy, contains('byte-for-byte'));
    expect(policy, contains('raw URL on its own line'));
    expect(policy, contains('otherwise omit it'));
    expect(policy, contains('Use only this customer'));
    expect(policy.split(RegExp(r'\s+')).length, lessThan(650));
    expect(request['attached_video_frame_paths'], isEmpty);
    expect(request['attached_image_paths'], [photo.path]);
    expect(request['video_report_preflight']['unreported_message_ids'],
        ['visible-video:reused:1792121167']);
  });

  test('capacity failure retries primary model then uses fallback', () async {
    final root = await Directory.systemTemp.createTemp('jd_capacity_fallback_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    final modelLog = File('${root.path}/models.log');
    final cards = await Directory('${knowledge.path}/rag_cards').create();
    await File('${cards.path}/customer_service_rag_cards.jsonl').writeAsString(
        '{"id":"usb_connection","status":"active","keywords":["USB","connecting"],"reply_template":"Check USB connection."}\n');
    final fakeCodex = File('${root.path}/fake-codex.sh');
    await fakeCodex.writeAsString('''#!/bin/sh
output=''
model=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  elif [ "\$1" = '--model' ]; then
    shift
    model="\$1"
  fi
  shift
done
cat >/dev/null
printf '%s\n' "\$model" >> "${modelLog.path}"
if [ "\$model" = 'gpt-6.1-sol' ]; then
  printf '%s\n' '{"type":"error","message":"Selected model is at capacity. Please try a different model."}'
  exit 1
fi
printf '%s\n' '{"reply":"Recovered with fallback.","decision":"draft","confidence":0.9,"used_record_ids":["usb_connection"],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"untrusted","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
printf '%s\n' '{"type":"thread.started","thread_id":"fallback-thread"}'
''');
    expect((await Process.run('chmod', ['+x', fakeCodex.path])).exitCode, 0);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:capacity-test',
      customerName: 'capacity-test',
      customerExternalId: 'capacity-test',
      capturedAt: DateTime.now(),
      messages: const [
        CapturedMessage(
          stableId: 'question',
          direction: 'incoming',
          body: 'My printer is not connecting by USB. How can I fix it?',
          axPath: 'test',
        ),
      ],
    ));
    final service = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory: knowledge,
      outputSchema: File('${root.path}/reply.schema.json'),
      capacityRetryDelays: const [Duration.zero],
    );

    final draft = await service.generate(
      conversation: (await database.conversations()).single,
      database: database,
    );

    expect(draft.reply, 'Recovered with fallback.');
    expect(draft.model, 'gpt-5.6-luna');
    expect(
      (await modelLog.readAsLines()),
      ['gpt-6.1-sol', 'gpt-6.1-sol', 'gpt-5.6-luna'],
    );
  });

  test('Codex timeout leaves the customer batch pending for retry', () async {
    final root = await Directory.systemTemp.createTemp('jd_codex_timeout_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    final photo = File(await (await database.history).saveMedia(
        userId: 'buyer', filename: 'customer.png', bytes: [1, 2, 3]));
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.now(),
      messages: [
        CapturedMessage(
          stableId: 'image-first',
          direction: 'incoming',
          body: '[Customer sent an image]',
          axPath: 'test',
          media: [CapturedMedia(type: 'image', path: photo.path)],
        ),
      ],
    ));
    final fakeCodex = File('${root.path}/slow-codex.sh');
    await fakeCodex.writeAsString('#!/bin/sh\nexec sleep 3\n');
    expect((await Process.run('chmod', ['+x', fakeCodex.path])).exitCode, 0);
    final service = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory: knowledge,
      outputSchema: File('${root.path}/reply.schema.json'),
      timeout: const Duration(milliseconds: 100),
    );
    await expectLater(
      service.generate(
        conversation: (await database.conversations()).single,
        database: database,
      ),
      throwsA(isA<CodexGenerationTimedOut>()),
    );
    expect(await database.hasPendingUnanswered('buyer'), isTrue);
    final job = (await database.slaFallbackJob('buyer'))!;
    expect(await database.hasUndeliveredDraft('buyer'), isFalse);
    expect(
        await database.reserveSlaFallback(
            userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt),
        isTrue);
    await database.markSlaFallbackSent(
      userId: 'buyer',
      messageId: job.messageId,
      reply: 'One moment, please. We are checking your question.',
    );
    expect(await database.hasPendingUnanswered('buyer'), isTrue);
    expect(await database.slaFallbackJob('buyer'), isNull);

    await expectLater(
      service.generate(
        conversation: (await database.conversations()).single,
        database: database,
      ),
      throwsA(isA<CodexGenerationTimedOut>()),
    );
    expect(await database.slaFallbackJob('buyer'), isNull);
    expect(
        await database.reserveSlaFallback(
            userId: 'buyer', messageId: job.messageId, dueAt: job.dueAt),
        isFalse);

    await fakeCodex.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat >/dev/null
printf '%s\\n' '{"reply":"Here is the verified answer.","decision":"draft","confidence":0.9,"used_record_ids":[],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
''');
    final recovered = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory: knowledge,
      outputSchema: File('${root.path}/reply.schema.json'),
      timeout: const Duration(seconds: 2),
    );
    final pending = (await database.conversations()).single;
    final finalDraft = await recovered.generate(
      conversation: pending,
      database: database,
    );
    expect(
        await database.saveDraft(pending.id, finalDraft,
            expectedMessageId: job.messageId),
        1);
    expect(
        await database.markReplySent(userId: 'buyer', reply: finalDraft.reply),
        isTrue);
    expect(await database.hasPendingUnanswered('buyer'), isFalse);
    final history = await (await database.history).read('buyer');
    expect((history!['messages'] as List<Object?>), hasLength(3));
  });

  test('feature replies receive exact JD catalog model evidence', () async {
    final root = await Directory.systemTemp.createTemp('jd_model_evidence_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final requestFile = File('${root.path}/request.txt');
    final fakeCodex = File('${root.path}/fake-codex.sh');
    await fakeCodex.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat > "${requestFile.path}"
printf '%s\\n' '{"reply":"The documented paper width is available.","decision":"draft","confidence":0.9,"used_record_ids":["product_model_feature_catalog"],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
''');
    expect((await Process.run('chmod', ['+x', fakeCodex.path])).exitCode, 0);
    final service = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory:
          Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
      outputSchema: File('${root.path}/reply.schema.json'),
    );

    for (final (model, question, expectedWidth) in [
      ('TP730', 'what are the features for tp730?', '30–100mm'),
      ('TP874', 'what features tp874 offers?', '30–80mm'),
    ]) {
      await database.saveCapture(CapturedConversation(
        stableKey: 'customer:$model',
        customerName: model,
        customerExternalId: model,
        capturedAt: DateTime.now(),
        messages: [
          CapturedMessage(
              stableId: 'question-$model',
              direction: 'incoming',
              body: question,
              axPath: 'test'),
        ],
      ));
      final conversation = (await database.conversations())
          .firstWhere((conversation) => conversation.userId == model);
      await service.generate(conversation: conversation, database: database);
      final requestText = await requestFile.readAsString();
      final payload = jsonDecode(requestText
          .split('<request_json>')[1]
          .split('</request_json>')[0]) as Map<String, dynamic>;
      expect(payload['product_feature_requested'], isTrue);
      final rows = (payload['verified_model_catalog_rows'] as List<Object?>)
          .whereType<Map<String, dynamic>>()
          .map((row) => row['source_row'].toString())
          .join('\n');
      expect(rows, contains(expectedWidth));
      expect(payload['product_model_feature_catalog'], isNotNull);
    }
  });

  test('Codex-classified second transfer request requires review', () async {
    final root = await Directory.systemTemp.createTemp('jd_transfer_intent_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    final counter = File('${root.path}/attempt-count');
    final fakeCodex = File('${root.path}/fake-codex.sh');
    await fakeCodex.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat >/dev/null
count=0
if [ -f "${counter.path}" ]; then count=\$(cat "${counter.path}"); fi
count=\$((count + 1))
printf '%s' "\$count" > "${counter.path}"
if [ "\$count" -eq 1 ]; then
  printf '%s\\n' '{"reply":"What problem are you experiencing?","decision":"draft","confidence":0.9,"used_record_ids":[],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"human_transfer_request_message_ids":["first"],"reason":null}' > "\$output"
else
  printf '%s\\n' '{"reply":"My colleague can help you.","decision":"draft","confidence":0.9,"used_record_ids":[],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"human_transfer_request_message_ids":["first","second"],"reason":null}' > "\$output"
fi
''');
    expect((await Process.run('chmod', ['+x', fakeCodex.path])).exitCode, 0);
    final start = DateTime.utc(2026, 9, 21, 5, 45);
    Future<void> capture(List<CapturedMessage> messages, DateTime at) =>
        database
            .saveCapture(CapturedConversation(
              stableKey: 'customer:transfer-intent',
              customerName: 'transfer-intent',
              customerExternalId: 'transfer-intent',
              capturedAt: at,
              messages: messages,
            ))
            .then((_) {});
    const firstMessage = CapturedMessage(
      stableId: 'first',
      direction: 'incoming',
      body: 'transfer me to human agent',
      axPath: 'test',
    );
    const secondMessage = CapturedMessage(
      stableId: 'second',
      direction: 'incoming',
      body: 'no, please transfer',
      axPath: 'test',
    );
    await capture([firstMessage], start);
    final service = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory: knowledge,
      outputSchema: File('${root.path}/reply.schema.json'),
    );
    final first = await service.generate(
      conversation: (await database.conversations()).single,
      database: database,
    );
    expect(first.decision, 'ask_clarification');
    expect(draftRequiresHumanReview(first), isFalse);

    await capture(
        [firstMessage, secondMessage], start.add(const Duration(minutes: 1)));
    final second = await service.generate(
      conversation: (await database.conversations()).single,
      database: database,
    );
    expect(draftRequiresHumanReview(second), isTrue);
    expect(second.reply, contains('客服同事'));
    expect(await counter.readAsString(), '2');
    final rows = await (await database.database).query(
      'human_transfer_requests',
      where: 'user_id = ?',
      whereArgs: ['transfer-intent'],
    );
    expect(rows.single['request_count'], 0);
  });

  test('an unresolved technical answer gets one fresh second investigation',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_second_pass_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    final ragCards =
        await Directory('${knowledge.path}/rag_cards').create(recursive: true);
    await File('${ragCards.path}/customer_service_rag_cards.jsonl').writeAsString(
        '{"id":"safe_restart","status":"active","keywords":["printer","not working","USB"],"issue":"printer USB recovery","reply_template":"Restart the printer and reconnect the USB cable."}\n');
    final counter = File('${root.path}/attempt-count');
    final fakeCodex = File('${root.path}/fake-codex.sh');
    await fakeCodex.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat >/dev/null
count=0
if [ -f "${counter.path}" ]; then count=\$(cat "${counter.path}"); fi
count=\$((count + 1))
printf '%s' "\$count" > "${counter.path}"
if [ "\$count" -eq 1 ]; then
  printf '%s\\n' '{"reply":"I cannot resolve this technical printer issue.","decision":"human_review_required","confidence":0.4,"used_record_ids":[],"required_slots":[],"actions":[],"risk_level":"high","risk_triggers":["unresolved printer issue"],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":true,"reason":"No solution found"}' > "\$output"
else
  printf '%s\\n' '{"reply":"Restart the printer, then reconnect the USB cable and print one test page.","decision":"draft","confidence":0.8,"used_record_ids":["safe_restart"],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
fi
''');
    expect((await Process.run('chmod', ['+x', fakeCodex.path])).exitCode, 0);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:second-pass',
      customerName: 'second-pass',
      customerExternalId: 'second-pass',
      capturedAt: DateTime.now(),
      messages: const [
        CapturedMessage(
          stableId: 'technical-question',
          direction: 'incoming',
          body: 'My printer is not working. How can I fix it?',
          axPath: 'test',
        ),
      ],
    ));
    final service = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory: knowledge,
      outputSchema: File('${root.path}/reply.schema.json'),
    );

    final draft = await service.generate(
      conversation: (await database.conversations()).single,
      database: database,
    );

    expect(await counter.readAsString(), '2');
    expect(draft.decision, 'draft');
    expect(draft.reply, contains('Restart the printer'));
    expect(draftRequiresHumanReview(draft), isFalse);
  });

  test('an unconfirmed product fact gets one full second lookup', () async {
    final root = await Directory.systemTemp.createTemp('jd_product_recheck_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final counter = File('${root.path}/attempt-count');
    final fakeCodex = File('${root.path}/fake-codex.sh');
    await fakeCodex.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
cat >/dev/null
count=0
if [ -f "${counter.path}" ]; then count=\$(cat "${counter.path}"); fi
count=\$((count + 1))
printf '%s' "\$count" > "${counter.path}"
if [ "\$count" -eq 1 ]; then
  printf '%s\n' '{"reply":"The TP730 driver is not confirmed in the current product information.","decision":"human_review_required","confidence":0.5,"used_record_ids":[],"required_slots":[],"actions":[],"risk_level":"high","risk_triggers":["unconfirmed driver"],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":true,"reason":"Not found on first pass"}' > "\$output"
else
  printf '%s\n' '{"reply":"The TP730 Windows driver is documented in the matching product manual.","decision":"draft","confidence":0.9,"used_record_ids":["thermal_driver_install_recognition_20260921"],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
fi
''');
    expect((await Process.run('chmod', ['+x', fakeCodex.path])).exitCode, 0);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:product-recheck',
      customerName: 'product-recheck',
      customerExternalId: 'product-recheck',
      capturedAt: DateTime.now(),
      messages: const [
        CapturedMessage(
          stableId: 'driver-question',
          direction: 'incoming',
          body: 'Where is the TP730 driver?',
          axPath: 'test',
        ),
      ],
    ));
    final service = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory:
          Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
      outputSchema: File('${root.path}/reply.schema.json'),
    );

    final draft = await service.generate(
      conversation: (await database.conversations()).single,
      database: database,
    );

    expect(await counter.readAsString(), '2');
    expect(draft.reply, contains('matching product manual'));
    expect(draft.decision, 'draft');
    expect(draftRequiresHumanReview(draft), isFalse);
  });

  test('explicit cancellation stops a Codex process promptly', () async {
    final root = await Directory.systemTemp.createTemp('jd_codex_cancel_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    final photo = File(await (await database.history).saveMedia(
        userId: 'buyer', filename: 'customer.png', bytes: [1, 2, 3]));
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.now(),
      messages: [
        CapturedMessage(
          stableId: 'image-first',
          direction: 'incoming',
          body: '[Customer sent an image]',
          axPath: 'test',
          media: [CapturedMedia(type: 'image', path: photo.path)],
        ),
      ],
    ));
    final started = File('${root.path}/started');
    final fakeCodex = File('${root.path}/slow-codex.sh');
    await fakeCodex.writeAsString('''#!/bin/sh
: > "${started.path}"
exec sleep 30
''');
    expect((await Process.run('chmod', ['+x', fakeCodex.path])).exitCode, 0);
    final service = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory: knowledge,
      outputSchema: File('${root.path}/reply.schema.json'),
    );
    final cancellation = CodexGenerationCancellation();
    final generation = service.generate(
      conversation: (await database.conversations()).single,
      database: database,
      cancellation: cancellation,
    );
    for (var attempt = 0; attempt < 200 && !await started.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await started.exists(), isTrue);
    cancellation.cancel();
    await expectLater(
      generation.timeout(const Duration(seconds: 4)),
      throwsA(isA<CodexGenerationCancelled>()),
    );
  });

  test('one Codex call per reply resumes only after actual delivery', () async {
    final root = await Directory.systemTemp.createTemp('jd_codex_flow_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    final log = File('${root.path}/codex-arguments.txt');
    final fakeCodex = File('${root.path}/fake-codex.sh');
    await fakeCodex.writeAsString('''#!/bin/sh
printf '%s\\n' "\$*" >> "${log.path}"
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then
    shift
    output="\$1"
  fi
  shift
done
printf '%s\\n' '{"reply":"Check the date settings.","decision":"draft","confidence":0.9,"used_record_ids":[],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
printf '%s\\n' '{"type":"thread.started","thread_id":"thread-for-customer"}'
''');
    expect((await Process.run('chmod', ['+x', fakeCodex.path])).exitCode, 0);
    final service = CodexReplyService(
      executable: fakeCodex.path,
      workspace: workspace,
      knowledgeDirectory: knowledge,
      outputSchema: File('${root.path}/reply.schema.json'),
      sessionStore: CustomerCodexSessionStore(
          Directory('${root.path}/data/codex_sessions')),
    );

    Future<void> capture(String id, String body) => database
        .saveCapture(
          CapturedConversation(
            stableKey: 'customer:buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            capturedAt: DateTime.now(),
            messages: [
              CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: body,
                axPath: 'test',
              ),
            ],
          ),
        )
        .then((_) {});

    await capture('question-1', 'How do I change the product date?');
    final first = await service.generate(
      conversation: (await database.conversations()).single,
      database: database,
    );
    await (await database.history).appendSentReply(
      userId: 'buyer',
      displayName: 'buyer',
      stableKey: 'customer:buyer',
      draft: first,
    );

    await capture('question-2', 'Where is that date setting?');
    await service.generate(
      conversation: (await database.conversations()).single,
      database: database,
    );

    // The second suggestion was generated, but never delivered.
    await capture('question-3', 'Can you explain the step?');
    await service.generate(
      conversation: (await database.conversations()).single,
      database: database,
    );

    final invocations = await log.readAsLines();
    expect(invocations, hasLength(3));
    expect(invocations[0], isNot(contains('exec resume')));
    expect(invocations[1], contains('exec resume'));
    expect(invocations[1], contains('thread-for-customer'));
    expect(invocations[2], isNot(contains('exec resume')));
  });
}
