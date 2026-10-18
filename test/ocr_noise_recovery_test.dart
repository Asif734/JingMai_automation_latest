import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/ocr_text_sanitizer.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  const customer = 'jd_41aeec7741d05';
  final at = DateTime.utc(2026, 10, 16, 5, 24, 12);
  OcrObservation line(String text, double y, {double confidence = 1}) =>
      OcrObservation(
          text: text,
          confidence: confidence,
          x: .22,
          y: y,
          width: .2,
          height: .02);
  OcrInspection view(List<OcrObservation> observations,
          {List<OcrVisualRegion> regions = const []}) =>
      OcrInspection(
          image: Uint8List(0),
          imageWidth: 1600,
          imageHeight: 1200,
          windowTitle: 'JD',
          recognizedText: '',
          capturedAt: at,
          activeCustomerId: customer,
          observations: observations,
          visualRegions: regions,
          chatLeft: .18,
          chatRight: .8,
          chatBottom: .9);

  test('isolated D E and boxes leave the sender unread, not a fake text turn',
      () {
    for (final fragment in [
      'D',
      'E',
      'D E',
      'D E □',
      '▢',
      '◎ 回',
      'g 回',
      'の ¿ 回'
    ]) {
      final result = const OcrCaptureExtractor().analyze(
          view([line('$customer 13:24:12', .30), line(fragment, .35)]));
      expect(result.capture, isNull, reason: fragment);
      expect(result.latestIncomingHasText, isFalse, reason: fragment);
      expect(result.latestIncomingSentAt, at, reason: fragment);
    }
  });
  test('removes control fragments without eating actual short replies or codes',
      () {
    expect(sanitizeJdOcrText('both are not working D E □'),
        'both are not working');
    expect(sanitizeJdOcrText('how are you doing? 复制'), 'how are you doing?');
    for (final body in [
      'yes',
      'no',
      'A',
      'B',
      'I',
      'a',
      'A4',
      'M880D',
      'TH880G',
      'E05',
      'E-05',
      '#E-s21',
      'press D',
      'option E',
      'I chose D',
      '我要复制'
    ]) {
      expect(sanitizeJdOcrText(body), body, reason: body);
    }
  });
  test('multi-line new JD warning is metadata, never customer intent', () {
    final result = const OcrCaptureExtractor().analyze(view([
      line('$customer 13:24:12', .30),
      line('i need help?', .35),
      line('当前消息可能包含辱骂、诋毁、讥刺等引起消费者不满的服务态度问题，', .4),
      line('京东有权视违规程度采取处理措施。点击查看规则详情 异常反馈', .44)
    ]));
    expect(result.capture!.messages.single.body, 'i need help?');
  });
  test(
      'masking media preserves approved low-confidence text and excludes image text',
      () {
    const image =
        OcrVisualRegion(x: .2, y: .34, width: .3, height: .15, confidence: 1);
    final scan = view([
      line('$customer 13:24:10', .30),
      line('text printed inside image', .38),
      line('$customer 13:24:12', .55),
      line('how are you doing?', .60, confidence: .35)
    ], regions: [
      image
    ]);
    final relaxed =
        const OcrCaptureExtractor(bodyConfidenceThreshold: .30).analyze(scan);
    expect(
        const OcrCaptureExtractor()
            .analyze(scan, excludedMediaRegions: [image]).capture,
        isNull);
    final masked = relaxed.textExcludingMedia(scan, [image]);
    expect(masked!.messages.single.body, 'how are you doing?');
    expect(masked.messages.single.sentAt, at);
  });
  test(
      'reject mixed sender crops, low-confidence headers and platform warning crops',
      () {
    const selector = OcrImageCandidateSelector();
    const region =
        OcrVisualRegion(x: .2, y: .35, width: .3, height: .35, confidence: 1);
    for (final metadata in [
      'jd_41aeec7741d05 13:24:13',
      '13:24:13 格志打印机小甘',
      '当前消息可能包含辱骂、诋毁、讥刺',
      '异常反馈',
      '已读'
    ]) {
      final scan = view([
        line('$customer 13:24:12', .30),
        line(metadata, .5, confidence: .35)
      ], regions: [
        region
      ]);
      expect(selector.select(scan, customer, includeTextDense: true), isEmpty,
          reason: metadata);
      expect(
          selector.shouldSaveImage(region, scan.observations,
              fromVerifiedCache: false),
          isFalse,
          reason: metadata);
    }
  });
  for (final pair in [
    ['how are you doing', 'how are you doing?'],
    ['ineed help', 'i need help?']
  ]) {
    test(
        'new timestamp is new work despite old punctuation/spacing variant: $pair',
        () async {
      final root = await Directory.systemTemp.createTemp('jd_text_recovery_');
      final database = CaptureDatabase(storageRoot: root);
      addTearDown(() async {
        await database.close();
        await root.delete(recursive: true);
      });
      CapturedConversation capture(String id, String body, DateTime stamp) =>
          CapturedConversation(
              stableKey: 'customer:$customer',
              customerName: customer,
              customerExternalId: customer,
              capturedAt: stamp.add(const Duration(seconds: 2)),
              messages: [
                CapturedMessage(
                    stableId: id,
                    direction: 'incoming',
                    body: body,
                    sender: customer,
                    sentAt: stamp,
                    axPath: 'ocr:test')
              ]);
      await database.saveCapture(
          capture('old', pair.first, at.subtract(const Duration(days: 1))));
      await database.saveCapture(capture('new', pair.last, at));
      expect(await database.pendingMessageId(customer), 'new');
      final store = await database.history;
      expect((await store.read(customer))!['messages'], hasLength(2));
      await database.saveCapture(capture('same-bubble', pair.first, at));
      expect((await store.read(customer))!['messages'], hasLength(2));
      await database.saveCapture(
          capture('noise', 'D E □', at.add(const Duration(seconds: 1))));
      expect((await store.read(customer))!['messages'], hasLength(2));
      expect(await database.pendingMessageId(customer), 'new');
    });
  }
}
