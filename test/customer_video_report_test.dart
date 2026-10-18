import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/customer_video_report.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

Map<String, dynamic> eventMessage(
        String id, String time, List<String> frames) =>
    {
      'id': id,
      'direction': 'incoming',
      'sent_at': time,
      'body': '',
      'media': [
        for (final path in frames)
          {
            'type': 'image',
            'path': path,
            'capture_source': 'jd_video_frame_1fps'
          },
        {'type': 'video', 'content_sha256': 'same-video-hash'}
      ],
    };
Map<String, dynamic> reportFor(CustomerVideoEvent event) => {
      'user_id': event.customer,
      'message_id': event.messageId,
      'sent_at': event.sentAt,
      'summary': 'A printer feeds paper partway, then stops.',
      'observed_problem': 'Paper stops halfway during feeding.',
      'search_terms': ['paper feed stops halfway', '进纸中途停止'],
      'uncertainties': ['Cause and exact model are not visible.'],
      'frames': [
        for (final path in event.frames)
          {
            'path': path,
            'description': 'Paper partially protrudes from the printer.'
          }
      ],
    };
String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final event = CustomerVideoEvent('A',
      eventMessage('v1', '2026-10-18T05:31:57Z', ['/A/f1.jpg', '/A/f2.jpg']));
  test('strict report validates every frame and exact customer event', () {
    final report = CustomerVideoReport.parse(event, reportFor(event));
    expect(report.descriptions.length, 2);
    expect(report.retrievalText, contains('进纸中途停止'));
    expect(CustomerVideoReport.cached(event, report.toJson()), isNotNull);
    for (final change in <Map<String, dynamic>>[
      {'user_id': 'B'},
      {'message_id': 'v2'},
      {'sent_at': '2026-10-18T05:32:57Z'},
      {
        'frames': [
          {'path': '/B/f1.jpg', 'description': 'Other customer'}
        ]
      },
      {
        'frames': [
          {'path': '/A/f1.jpg', 'description': 'Only one'}
        ]
      },
      {
        'frames': [
          {'path': '/A/f1.jpg', 'description': 'one'},
          {'path': '/A/f1.jpg', 'description': 'duplicate'}
        ]
      },
    ]) {
      expect(
          () => CustomerVideoReport.parse(
              event, {...reportFor(event), ...change}),
          throwsFormatException);
    }
  });
  test('identical bytes at a new timestamp or customer require a new report',
      () {
    final report = CustomerVideoReport.parse(event, reportFor(event));
    for (final changed in [
      CustomerVideoEvent('B', eventMessage('v1', event.sentAt!, event.frames)),
      CustomerVideoEvent(
          'A', eventMessage('v2', '2026-10-18T05:32:57Z', event.frames)),
    ]) {
      expect(changed.fingerprint, isNot(event.fingerprint));
      expect(CustomerVideoReport.cached(changed, report.toJson()), isNull);
    }
  });

  test('legacy short-prepass failures do not suppress the new analysis', () {
    final failed = {
      'status': 'unavailable',
      'user_id': event.customer,
      'message_id': event.messageId,
      'source_fingerprint': event.fingerprint,
    };
    expect(videoReportPreviouslyUnavailable(event, failed), isFalse);
    expect(
        videoReportPreviouslyUnavailable(event, {
          ...failed,
          'analysis_policy_version': customerVideoAnalysisPolicyVersion,
        }),
        isTrue);
  });

  for (final behavior in [
    'valid',
    'slow_valid',
    'cross_customer',
    'invalid',
    'timeout',
    'valid_second',
    'invalid_second',
    'timeout_second'
  ]) {
    test('report-first generation: $behavior, no JD UI or live Codex',
        () async {
      final secondInspection = behavior.endsWith('_second');
      final slowStages = behavior == 'slow_valid';
      final reportBehavior = slowStages
          ? 'valid'
          : secondInspection
              ? behavior.substring(0, behavior.length - '_second'.length)
              : behavior;
      final root =
          await Directory.systemTemp.createTemp('jd_video_report_test_');
      final db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final workspace = await Directory('${root.path}/workspace').create();
      final knowledge = await Directory('${root.path}/knowledge').create();
      final cards = await Directory('${knowledge.path}/rag_cards').create();
      await File('${cards.path}/customer_service_rag_cards.jsonl')
          .writeAsString(jsonEncode({
        'id': 'paper-feed-record',
        'status': 'active',
        'keywords': ['paper feed stops halfway', '进纸中途停止'],
        'reply_template': 'Check the paper guide for correct alignment.'
      }));
      final store = await db.history;
      final frames = [
        for (final n in [1, 2])
          await store
              .saveMedia(userId: 'A', filename: 'frame$n.jpg', bytes: [n])
      ];
      final stamp = DateTime.utc(2026, 10, 18, 5, 31, 57);
      Future<void> addVideo(String id, DateTime time) =>
          db.saveCapture(CapturedConversation(
              stableKey: 'A',
              customerName: 'A',
              customerExternalId: 'A',
              capturedAt: time,
              messages: [
                CapturedMessage(
                    stableId: id,
                    direction: 'incoming',
                    body: '[Customer sent a video]',
                    sentAt: time,
                    axPath: 'test',
                    media: [
                      for (final path in frames)
                        CapturedMedia(
                            type: 'image',
                            path: path,
                            captureSource: 'jd_video_frame_1fps')
                    ])
              ]));
      await addVideo('v1', stamp);
      // A second event can reuse bytes but must retain its own report receipt.
      await addVideo('v2', stamp.add(const Duration(seconds: 30)));
      await db.saveCapture(CapturedConversation(
          stableKey: 'A',
          customerName: 'A',
          customerExternalId: 'A',
          capturedAt: stamp.add(const Duration(seconds: 40)),
          messages: [
            CapturedMessage(
                stableId: 'q1',
                direction: 'incoming',
                body: 'What do you see in these videos?',
                sentAt: stamp.add(const Duration(seconds: 40)),
                axPath: 'test')
          ]));
      final document = (await store.read('A'))!;
      final events = (document['messages'] as List)
          .whereType<Map<String, dynamic>>()
          .where((m) => m['id'] == 'v1' || m['id'] == 'v2')
          .map((m) => CustomerVideoEvent('A', m))
          .toList();
      final reports = [for (final e in events) reportFor(e)];
      if (reportBehavior == 'cross_customer') {
        for (final report in reports) {
          report['user_id'] = 'B';
        }
      }
      final fake = File('${root.path}/fake.sh');
      final sequence = File('${root.path}/sequence');
      final reportInput = File('${root.path}/report-input.json');
      final finalInput = File('${root.path}/answer-input');
      final pidFile = File('${root.path}/report-pid');
      final answer = jsonEncode({
        'reply':
            'I can see paper partly protruding from the printer. What would you like me to check?',
        'decision': 'ask_clarification',
        'confidence': 0.9,
        'used_record_ids': [],
        'required_slots': ['customer concern'],
        'actions': [],
        'risk_level': 'low',
        'risk_triggers': [],
        'auto_send_allowed': false,
        'model': 'test',
        'attachments': [],
        'image_descriptions': [],
        'human_review_required': false,
        'reason': null
      });
      final firstAnswer = jsonEncode({
        ...(jsonDecode(answer) as Map<String, dynamic>),
        'reply':
            'Your paper feed issue needs checking by a customer service colleague. I’ll request further technical review.',
        'decision': 'draft',
        'required_slots': [],
      });
      await fake.writeAsString('''#!/bin/sh
output=''
schema=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output-last-message) shift; output="\$1";;
    --output-schema) shift; schema="\$1";;
  esac
  shift
done
case "\$schema" in
  *video-report.schema.json)
    printf 'report\\n' >> ${quote(sequence.path)}
    cat >> ${quote(reportInput.path)}
    printf '\\n' >> ${quote(reportInput.path)}
    ${slowStages ? 'sleep 4' : ''}
    ${reportBehavior == 'timeout' ? 'echo \$\$ > ${quote(pidFile.path)}\n    exec sleep 30' : '''if [ ! -f ${quote('${root.path}/first-report-done')} ]; then
      printf 'done' > ${quote('${root.path}/first-report-done')}
      printf '%s' ${quote(reportBehavior == 'invalid' ? 'not JSON' : jsonEncode({
                      'reports': [reports.first]
                    }))} > "\$output"
    else
      printf '%s' ${quote(reportBehavior == 'invalid' ? 'not JSON' : jsonEncode({
                      'reports': [reports.last]
                    }))} > "\$output"
    fi'''}
    ;;
  *)
    printf 'answer\\n' >> ${quote(sequence.path)}
    cat > ${quote(finalInput.path)}
    ${slowStages ? 'sleep 1' : ''}
    ${secondInspection ? '''if [ ! -f ${quote('${root.path}/first-answer-done')} ]; then
      printf 'done' > ${quote('${root.path}/first-answer-done')}
      printf '%s' ${quote(firstAnswer)} > "\$output"
      exit 0
    fi''' : ''}
    printf '%s' ${quote(answer)} > "\$output"
    ;;
esac
''');
      expect((await Process.run('chmod', ['+x', fake.path])).exitCode, 0);
      final diagnostics = <String>[];
      final service = CodexReplyService(
          executable: fake.path,
          workspace: workspace,
          knowledgeDirectory: knowledge,
          outputSchema: File('${root.path}/reply.schema.json'),
          timeout: slowStages
              ? const Duration(seconds: 6)
              : const Duration(seconds: 100),
          videoReportTimeout: reportBehavior == 'timeout'
              ? const Duration(seconds: 3)
              : slowStages
                  ? const Duration(seconds: 10)
                  : const Duration(seconds: 5),
          onDiagnostic: (name, fields) => diagnostics.add(name));
      final conversation = (await db.conversations()).single;
      final clock = Stopwatch()..start();
      final draft =
          await service.generate(conversation: conversation, database: db);
      if (slowStages) {
        expect(clock.elapsed, greaterThan(const Duration(seconds: 9)),
            reason:
                'Two independent 4s analyses plus a 1s reply exceed the 6s reply budget but must succeed.');
      }
      expect(draft.decision, 'ask_clarification');
      expect(draft.reply, isNot(contains('[Customer sent')));
      expect((await sequence.readAsLines()).take(3),
          ['report', 'report', 'answer']);
      expect(
          diagnostics.indexOf('generation.reply_started'),
          greaterThan(
              diagnostics.lastIndexOf('generation.video_report_started')));
      if (secondInspection) {
        expect(await sequence.readAsLines(),
            ['report', 'report', 'answer', 'answer'],
            reason:
                'A failed/expired observation must not repeat during second inspection');
        expect(
            (jsonDecode(draft.rawJson) as Map)['retrieval_trace']
                ['inspection_attempt'],
            2);
      }
      final observed = (await reportInput.readAsLines())
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(
          observed
              .expand((item) => item['events'] as List)
              .map((e) => e['message_id']),
          ['v1', 'v2']);
      expect(observed.every((item) => (item['events'] as List).length == 1),
          isTrue);
      expect(
          observed
              .expand((item) => item['events'] as List)
              .every((e) => e['user_id'] == 'A'),
          isTrue);
      final prompt = await finalInput.readAsString();
      final request = jsonDecode(
              prompt.split('<request_json>\n')[1].split('\n</request_json>')[0])
          as Map;
      expect(request['attached_video_frame_paths'], isEmpty);
      expect(request['attached_image_paths'], isEmpty);
      expect(
          request['video_report_preflight']['original_frames_still_supplied'],
          isFalse);
      final saved = (await store.read('A'))!['messages'] as List;
      if (reportBehavior == 'valid') {
        expect(request['customer_video_reports'], hasLength(2));
        expect(prompt, contains('paper-feed-record'));
        expect(prompt, contains('进纸中途停止'));
        expect(draft.imageDescriptions.keys, containsAll(frames));
        expect(saved.where((m) => m['video_report'] != null), hasLength(2));
        await service.generate(conversation: conversation, database: db);
        expect((await sequence.readAsLines()).where((s) => s == 'report'),
            hasLength(2),
            reason:
                'Second inspection reuses only exact, verified event reports.');
      } else {
        expect(request['customer_video_reports'], isEmpty);
        expect(request['video_report_preflight']['unreported_message_ids'],
            ['v1', 'v2']);
        expect(saved.where((m) => m['video_report'] != null), isEmpty);
        expect(diagnostics, contains('generation.video_report_unavailable'));
        if (reportBehavior == 'timeout') {
          final pid = int.parse((await pidFile.readAsString()).trim());
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(Process.killPid(pid, ProcessSignal.sigcont), isFalse,
              reason: 'Timed-out owned report process must be gone.');
        }
        // A separate retry/service instance must reuse the failed attempt,
        // not just the second-inspection memo inside one generate() call.
        final retry = CodexReplyService(
            executable: fake.path,
            workspace: workspace,
            knowledgeDirectory: knowledge,
            outputSchema: File('${root.path}/reply.schema.json'),
            videoReportTimeout: const Duration(seconds: 3),
            onDiagnostic: (name, fields) => diagnostics.add(name));
        await retry.generate(conversation: conversation, database: db);
        expect((await sequence.readAsLines()).where((s) => s == 'report'),
            hasLength(2));
        expect(diagnostics, contains('generation.video_report_attempt_reused'));
        await addVideo('v3', stamp.add(const Duration(minutes: 2)));
        await retry.generate(
            conversation: (await db.conversations()).single, database: db);
        expect((await sequence.readAsLines()).where((s) => s == 'report'),
            hasLength(3),
            reason: 'A genuinely new timestamp must receive its own attempt');
      }
      expect(await store.read('B'), isNull);
    });
  }

  group('independent analysis and reply deadlines', () {
    late Directory root, workspace, knowledge;
    late CaptureDatabase db;
    late CustomerVideoEvent video;
    late File sequence;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('jd_video_stage_test_');
      db = CaptureDatabase(storageRoot: Directory('${root.path}/data'));
      workspace = await Directory('${root.path}/workspace').create();
      knowledge = await Directory('${root.path}/knowledge').create();
      sequence = File('${root.path}/sequence');
      final store = await db.history;
      final frame = await store
          .saveMedia(userId: 'A', filename: 'frame.jpg', bytes: [1, 2, 3]);
      final at = DateTime.utc(2026, 10, 18, 10);
      await db.saveCapture(CapturedConversation(
          stableKey: 'A',
          customerName: 'A',
          customerExternalId: 'A',
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: 'video-A',
                direction: 'incoming',
                body: 'What is visible in this video?',
                sentAt: at,
                axPath: 'test',
                media: [
                  CapturedMedia(
                      type: 'image',
                      path: frame,
                      captureSource: 'jd_video_frame_1fps')
                ])
          ]));
      final document = (await store.read('A'))!;
      video = CustomerVideoEvent('A', (document['messages'] as List).single);
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    Future<File> cli(String reportBody, String answerBody) async {
      final fake = File('${root.path}/fake.sh');
      await fake.writeAsString('''#!/bin/sh
output=''
schema=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output-last-message) shift; output="\$1";;
    --output-schema) shift; schema="\$1";;
  esac
  shift
done
cat >/dev/null
case "\$schema" in
  *video-report.schema.json)
    printf 'report\\n' >> ${quote(sequence.path)}
    $reportBody
    ;;
  *)
    printf 'answer\\n' >> ${quote(sequence.path)}
    $answerBody
    ;;
esac
''');
      expect((await Process.run('chmod', ['+x', fake.path])).exitCode, 0);
      return fake;
    }

    CodexReplyService service(File fake, Duration replyTimeout) =>
        CodexReplyService(
            executable: fake.path,
            workspace: workspace,
            knowledgeDirectory: knowledge,
            outputSchema: File('${root.path}/reply.schema.json'),
            timeout: replyTimeout,
            videoReportTimeout: const Duration(seconds: 5));

    test('reply timeout retains the report for a fresh retry', () async {
      final fake = await cli(
          'printf \'%s\' ${quote(jsonEncode({
                'reports': [reportFor(video)]
              }))} > "\$output"',
          '''if [ ! -f ${quote('${root.path}/first-answer-started')} ]; then
  printf 'done' > ${quote('${root.path}/first-answer-started')}
  exec sleep 30
fi
printf '%s' ${quote(jsonEncode({
            'reply': 'Which part would you like me to check?',
            'decision': 'ask_clarification',
            'confidence': 0.9,
            'used_record_ids': [],
            'required_slots': ['customer concern'],
            'actions': [],
            'risk_level': 'low',
            'risk_triggers': [],
            'auto_send_allowed': false,
            'attachments': [],
            'image_descriptions': [],
            'human_review_required': false,
            'reason': null,
          }))} > "\$output"''');
      final conversation = (await db.conversations()).single;
      await expectLater(
          service(fake, const Duration(seconds: 1))
              .generate(conversation: conversation, database: db),
          throwsA(isA<CodexGenerationTimedOut>()));
      final saved = (await (await db.history).read('A'))!;
      expect(
          CustomerVideoReport.cached(
              video, (saved['messages'] as List).first['video_report']),
          isNotNull);
      expect(await db.hasUndeliveredDraft('A'), isFalse);
      final reply = await service(fake, const Duration(seconds: 3))
          .generate(conversation: conversation, database: db);
      expect(reply.decision, 'ask_clarification');
      expect(reply.imageDescriptions.keys, video.frames);
      expect(await sequence.readAsLines(), ['report', 'answer', 'answer']);
    });

    test('analysis can be cancelled while another customer replies', () async {
      final pidFile = File('${root.path}/analysis-pid');
      final fake = await cli(
          'echo \$\$ > ${quote(pidFile.path)}\nexec sleep 30', 'exit 1');
      final cancellation = CodexGenerationCancellation();
      addTearDown(cancellation.cancel);
      final pending = service(fake, const Duration(seconds: 1)).generate(
          conversation: (await db.conversations()).single,
          database: db,
          cancellation: cancellation);
      final cancelled =
          expectLater(pending, throwsA(isA<CodexGenerationCancelled>()));
      final limit = DateTime.now().add(const Duration(seconds: 3));
      while (!await pidFile.exists() && DateTime.now().isBefore(limit)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await pidFile.exists(), isTrue);
      final at = DateTime.utc(2026, 10, 18, 10, 1);
      await db.saveCapture(CapturedConversation(
          stableKey: 'B',
          customerName: 'B',
          customerExternalId: 'B',
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: 'hi-B',
                direction: 'incoming',
                body: 'how are you doing?',
                sentAt: at,
                axPath: 'test')
          ]));
      final other = await service(fake, const Duration(seconds: 1))
          .generate(
              conversation: (await db.conversations())
                  .singleWhere((c) => c.userId == 'B'),
              database: db)
          .timeout(const Duration(seconds: 2));
      expect(other.usedRecordIds, ['intent:social_check_in']);
      expect(await sequence.readAsLines(), ['report']);
      cancellation.cancel();
      await cancelled.timeout(const Duration(seconds: 2));
      final pid = int.parse((await pidFile.readAsString()).trim());
      expect(Process.killPid(pid, ProcessSignal.sigcont), isFalse);
      final saved = (await (await db.history).read('A'))!;
      expect((saved['messages'] as List).first['video_report_attempt'], isNull,
          reason: 'Cancellation is not a completed unavailable analysis.');
    });
  });
}
