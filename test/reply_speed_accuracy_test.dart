import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  OcrInspection inspection({double confidence = 1, bool media = false}) =>
      OcrInspection(
        image: Uint8List(0),
        imageWidth: 1500,
        imageHeight: 1000,
        windowTitle: '咚咚融合工作台',
        recognizedText: '',
        activeCustomerId: 'buyer',
        capturedAt: DateTime.utc(2026, 10, 10, 9, 24, 25),
        observations: [
          const OcrObservation(
              text: 'buyer 17:24:21',
              confidence: 1,
              x: .22,
              y: .4,
              width: .21,
              height: .02),
          OcrObservation(
              text: '打4联可以的吧',
              confidence: confidence,
              x: .24,
              y: .44,
              width: .18,
              height: .02),
        ],
        visualRegions: media
            ? const [
                OcrVisualRegion(
                    x: .23, y: .47, width: .25, height: .2, confidence: 1)
              ]
            : const [],
      );

  test('fast scan starts clear text but defers uncertain text and media', () {
    const extractor = OcrCaptureExtractor();
    final text = extractor.verifiedFastTextCapture(inspection());
    expect(text?.messages.single.body, '打4联可以的吧');
    expect(text?.messages.single.sentAt, DateTime.utc(2026, 10, 10, 9, 24, 21));
    expect(
        extractor.verifiedFastTextCapture(inspection(confidence: .6)), isNull);
    expect(extractor.verifiedFastTextCapture(inspection(media: true)), isNull);
  });

  test('old confirmed TD630 survives prompt limit and retrieves copy evidence',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_speed_accuracy_');
    final database =
        CaptureDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });
    final workspace = await Directory('${root.path}/workspace').create();
    final requestFile = File('${root.path}/request.txt');
    final fake = File('${root.path}/fake-codex.sh');
    await fake.writeAsString('''#!/bin/sh
output=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--output-last-message' ]; then shift; output="\$1"; fi
  shift
done
cat > '${requestFile.path}'
printf '%s\\n' '{"reply":"可以，TD630支持六联，四联可以打印。","decision":"draft","confidence":0.99,"used_record_ids":["dot_matrix_copy_capacity"],"required_slots":[],"actions":[],"risk_level":"low","risk_triggers":[],"auto_send_allowed":false,"model":"test","attachments":[],"image_descriptions":[],"human_review_required":false,"reason":null}' > "\$output"
''');
    expect((await Process.run('chmod', ['+x', fake.path])).exitCode, 0);
    await database.saveCapture(CapturedConversation(
      stableKey: 'customer:buyer',
      customerName: 'buyer',
      customerExternalId: 'buyer',
      capturedAt: DateTime.now(),
      messages: [
        const CapturedMessage(
            stableId: 'model',
            direction: 'incoming',
            body: '我的是TD630',
            axPath: 'test'),
        for (var index = 0; index < 16; index++) ...[
          CapturedMessage(
              stableId: 'q$index',
              direction: 'incoming',
              body: '驱动用哪种，步骤$index',
              axPath: 'test'),
          CapturedMessage(
              stableId: 'a$index',
              direction: 'outgoing',
              body: '请用Windows通用驱动，USB连接，步骤$index',
              sentAt: DateTime.utc(2026, 10, 18, 1, index),
              deliveryConfirmed: true,
              axPath: 'test'),
        ],
        const CapturedMessage(
            stableId: 'copies',
            direction: 'incoming',
            body: '打4联可以的吧请稍等，我正在核对您刚发来的消息。',
            axPath: 'test'),
      ],
    ));
    final history = (await (await database.history).read('buyer'))!;
    for (final message
        in (history['messages'] as List).cast<Map<String, dynamic>>()) {
      if (message['direction'] == 'outgoing') {
        message['reply_metadata'] = {
          'raw_response': {'reason': 'audit-only' * 1500}
        };
      }
    }
    await File('${root.path}/data/buyer.json')
        .writeAsString(jsonEncode(history));
    final service = CodexReplyService(
      executable: fake.path,
      workspace: workspace,
      knowledgeDirectory:
          Directory('${Directory.current.path}/格志京东客服知识库-2026-10-04'),
      outputSchema: File('${root.path}/reply.schema.json'),
    );
    await service.generate(
        conversation: (await database.conversations()).single,
        database: database,
        batchEndMessageId: 'copies');
    final request = await requestFile.readAsString();
    final payload = jsonDecode(
            request.split('<request_json>')[1].split('</request_json>')[0])
        as Map<String, dynamic>;
    expect(payload['explicit_product_models'], ['td630']);
    expect(payload['product_feature_requested'], isTrue);
    expect(
        payload['requested_product_capabilities'], contains('copy_capacity'));
    expect(payload['latest_message']['body'], '打4联可以的吧');
    expect(payload['conversation'], hasLength(24));
    expect(payload, isNot(contains('previous_context')));
    expect(request, isNot(contains('audit-only')));
    expect(request.length, lessThan(40000));
    expect(
        (payload['retrieved_knowledge_records'] as List)
            .map((record) => record['id']),
        contains('dot_matrix_copy_capacity'));
    expect(payload['product_model_feature_catalog']['content'],
        isNot(contains('TP874')));
  });
}
