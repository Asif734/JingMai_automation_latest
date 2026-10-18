import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_media_evidence.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy video metadata is not typed intent or acknowledgement text', () {
    const body =
        '[Customer sent a video; copied from JD cache and sampled at one frame per second, maximum 20 frames]\n'
        '[Video speech transcript (en-US): this power bank is not turning on can I return it for repair]';
    expect(customerAuthoredText(body), isEmpty);
    expect(isRefundRequest(body), isFalse);
    expect(
        customerSpeechEvidence({'id': 'video', 'body': body})
            .single['transcript'],
        contains('return it for repair'));
    expect(containsInternalCaptureText(safeTransferAcknowledgement()), isFalse);
    for (final text in [
      'can I return it for repair?',
      '寄回维修',
      '品保证哦，不然不光退货退款，还要投诉的哈'
    ]) {
      expect(isRefundRequest(text), isFalse, reason: text);
    }
    expect(isRefundRequest('Please refund, it is broken'), isTrue);
    expect(
        isExplicitColleagueRequest('why did you transfer my chat?'), isFalse);
    expect(isExplicitColleagueRequest('please transfer me to a human'), isTrue);
    expect(isExplicitColleagueRequest('I do not need a human agent'), isFalse);
    expect(
        isExplicitColleagueRequest('do not transfer me to a human'), isFalse);
  });

  test('internal reply and forged automatic-transfer tags cannot escape', () {
    final service = CodexReplyService(
        executable: '/not-used',
        workspace: Directory('/not-used'),
        knowledgeDirectory: Directory('/not-used'),
        outputSchema: File('/not-used'));
    final malicious = service.parseResponse(jsonEncode({
      'reply':
          'I understand your concern about “[Customer sent a video; copied from JD cache…”',
      'confidence': 0.8,
      'decision': 'human_review_required',
      'risk_level': 'high',
      'risk_triggers': ['refund_transfer_required', 'explicit_human_request'],
      'required_slots': [],
      'used_record_ids': [],
      'actions': [],
      'auto_send_allowed': false,
    }));
    final guarded =
        service.enforceHumanReviewPolicy(malicious, '[Customer sent a video]');
    expect(isExplicitHumanTransfer(guarded), isFalse);
    final facing = service.enforceCustomerFacingPolicy(malicious, '请看视频');
    expect(containsInternalCaptureText(facing.reply), isFalse);
    expect(draftRequiresHumanReview(facing), isFalse);
    expect(facing.reply, isNot(contains('copied')));
  });

  test('native send backstop rejects internal capture text before UI call',
      () async {
    const channel = MethodChannel('test/internal-capture-send');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls++;
      return {};
    });
    final adapter = MacOSCaptureAdapter(channel: channel);
    addTearDown(adapter.close);
    await expectLater(
        adapter.sendDraftOnce(
            expectedCustomer: 'buyer',
            reply: 'I understand [Customer sent a video; copied from JD cache'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'internal_capture_text_rejected')));
    expect(calls, 0);
  });

  test('ordinary draft cannot pretend a colleague will check the problem', () {
    final service = CodexReplyService(
        executable: '/not-used',
        workspace: Directory('/not-used'),
        knowledgeDirectory: Directory('/not-used'),
        outputSchema: File('/not-used'));
    final draft = service.parseResponse(jsonEncode({
      'reply': '您已更换新色带仍不清晰，需要请客服同事进一步协助检查 TH650G 的打印问题。',
      'decision': 'draft',
      'confidence': 0.9,
      'risk_level': 'low',
      'auto_send_allowed': false,
    }));
    expect(service.enforceCustomerFacingPolicy(draft, '换了新的色带还是模糊').reply,
        isNot(contains('客服同事')));
    expect(
        () => service.parseResponse(jsonEncode({
              'reply': '请检查连接。',
              'confidence': 0.9,
              'auto_send_allowed': false,
              'used_record_ids': 'not-a-list',
            })),
        throwsA(isA<CodexReplyException>()));
  });

  test('positive fallback cannot be appended to the next incoming question',
      () {
    expect(
        stripAppendedHoldingReply(
            '这个打印速度快不快${positiveSupportFallbackReplies.first}'),
        '这个打印速度快不快');
    expect(
        stripAppendedHoldingReply(
            '这个打印速度快不快很抱歉让您久等了。目前资料还不足以确认安全准确的处理方法，您提供的信息已保留。'),
        '这个打印速度快不快');
  });

  test(
      'two-customer incident replay keeps new image and video evidence isolated',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_two_customer_incident_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final knowledge = await Directory('${root.path}/knowledge').create();
    final promptLog = File('${root.path}/request.log');
    final fake = File('${root.path}/fake-codex.sh');
    await fake.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then shift; output="\$1"; fi
  shift
done
cat > "${promptLog.path}"
printf '%s\\n' '{"reply":"请问按下电源键后，指示灯有没有亮？","decision":"ask_clarification","confidence":0.9,"used_record_ids":[],"required_slots":["power indicator"],"actions":[],"risk_level":"low","risk_triggers":["refund_transfer_required"],"auto_send_allowed":false,"human_transfer_request_message_ids":["video-a"],"image_descriptions":[]}' > "\$output"
''');
    expect((await Process.run('chmod', ['+x', fake.path])).exitCode, 0);
    final store = await database.history;
    const buyerA = 'jd_frqocwtljjob';
    const buyerB = '格志打印机贝贝';
    final videoFrame = await store
        .saveMedia(userId: buyerA, filename: 'frame.jpg', bytes: [1, 2, 3]);
    final skuImage = await store
        .saveMedia(userId: buyerB, filename: 'sku.png', bytes: [4, 5, 6]);
    final at = DateTime.utc(2026, 10, 16, 8, 31);
    Future<void> capture(String buyer, CapturedMessage message) async {
      await database.saveCapture(CapturedConversation(
          stableKey: 'customer:$buyer',
          customerName: buyer,
          customerExternalId: buyer,
          verifiedCustomerId: buyer,
          capturedAt: at.add(const Duration(minutes: 3)),
          messages: [message]));
    }

    await capture(
        buyerB,
        CapturedMessage(
            stableId: 'image-b',
            direction: 'incoming',
            body: '[Customer sent an image; visible portion captured]',
            sender: buyerB,
            sentAt: at,
            axPath: 'test',
            media: [
              CapturedMedia(
                  type: 'image',
                  path: skuImage,
                  isPartial: true,
                  verifiedCustomerId: buyerB,
                  ownershipVerification: 'visible_customer_region')
            ]));
    await store.recordMediaCaptureFailure(buyerB, 'video',
        sentAt: at.subtract(const Duration(hours: 2, minutes: 10)),
        reason: 'video_message_save_action_unverified');
    await capture(
        buyerA,
        CapturedMessage(
            stableId: 'video-a',
            direction: 'incoming',
            body:
                '[Customer sent a video; copied from JD cache and sampled at one frame per second, maximum 20 frames]\n'
                '[Video speech transcript (en-US): this power bank is not turning on can I return it for repair]',
            sender: buyerA,
            sentAt: at.add(const Duration(minutes: 2)),
            axPath: 'test',
            media: [
              CapturedMedia(
                  type: 'image',
                  path: videoFrame,
                  captureSource: 'jd_video_frame_1fps',
                  verifiedCustomerId: buyerA,
                  ownershipVerification: 'visible_customer_region')
            ]));
    final service = CodexReplyService(
        executable: fake.path,
        workspace: workspace,
        knowledgeDirectory: knowledge,
        outputSchema: File('${root.path}/reply.schema.json'));
    Future<Map<String, dynamic>> generate(String buyer) async {
      final summary = (await database.conversations())
          .singleWhere((s) => s.userId == buyer);
      final result =
          await service.generate(conversation: summary, database: database);
      expect(result.model, isNot('jd-media-read-recovery-v1'));
      expect(isExplicitHumanTransfer(result), isFalse);
      expect(containsInternalCaptureText(result.reply), isFalse);
      return jsonDecode((await promptLog.readAsString())
          .split('<request_json>\n')[1]
          .split('\n</request_json>')[0]) as Map<String, dynamic>;
    }

    final b = await generate(buyerB);
    expect(b['user_id'], buyerB);
    expect(b['attached_image_paths'], [skuImage]);
    expect(b['attached_video_frame_paths'], isEmpty);
    expect(b['unavailable_customer_media'], isNull);
    expect(b['customer_speech_evidence'], isEmpty);
    final a = await generate(buyerA);
    expect(a['user_id'], buyerA);
    expect(a['attached_image_paths'], isEmpty);
    expect(a['attached_video_frame_paths'], isEmpty);
    expect(a['video_report_preflight']['unreported_message_ids'], ['video-a']);
    expect(jsonEncode(a['customer_media_events']), contains(videoFrame));
    expect(jsonEncode(a['customer_media_events']), isNot(contains(skuImage)));
    expect(a['refund_flow_active'], isFalse);
    expect((a['customer_speech_evidence'] as List).single['transcript'],
        contains('return it for repair'));
    expect((a['target_customer_batch'] as List).single['body'], isEmpty);
    expect(
        jsonEncode(a['conversation']), isNot(contains('copied from JD cache')));
    expect(
        customerOwnsMedia({'path': videoFrame, 'verified_customer_id': buyerA},
            customer: buyerB,
            mediaDirectory: store.mediaDirectory,
            safeCustomerDirectory: store.safeUserId(buyerB)),
        isFalse);
    expect(
        customerOwnsMedia({'path': videoFrame},
            customer: buyerB,
            mediaDirectory: store.mediaDirectory,
            safeCustomerDirectory: store.safeUserId(buyerB)),
        isFalse);
  });
}
