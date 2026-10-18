import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_process_runner.dart';
import 'package:jd_automation/capture/video_audio_extractor.dart';
import 'package:jd_automation/capture/video_frame_extractor.dart';

void main() {
  test('bounded runner collects normal output', () async {
    final result = await const MediaProcessRunner()
        .run('/bin/echo', ['done'], timeout: const Duration(seconds: 1));
    expect(result.exitCode, 0);
    expect(result.stdout.toString().trim(), 'done');
  });
  test('decoder ignoring SIGTERM is killed and worker returns promptly',
      () async {
    final watch = Stopwatch()..start();
    MediaProcessTimedOut? failure;
    try {
      await const MediaProcessRunner().run(
          '/bin/sh', ['-c', "trap '' TERM; exec /bin/sleep 30"],
          timeout: const Duration(milliseconds: 100));
    } on MediaProcessTimedOut catch (e) {
      failure = e;
    }
    expect(failure, isNotNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(Process.killPid(failure!.pid!, ProcessSignal.sigterm), isFalse);
  });
  test('frame and audio timeouts preserve original, reject partial frame cache',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_decoder_timeout_');
    addTearDown(() => root.delete(recursive: true));
    final fake = File('${root.path}/decoder');
    await fake.writeAsString("#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 30\n");
    expect((await Process.run('/bin/chmod', ['+x', fake.path])).exitCode, 0);
    final video = File('${root.path}/original.mp4');
    await video.writeAsBytes([1, 2, 3]);
    final hash = sha256.convert([1, 2, 3]).toString();
    final frames =
        await Directory('${root.path}/frames_${hash.substring(0, 16)}')
            .create();
    await File('${frames.path}/frame_01.jpg').writeAsBytes([4]);
    await expectLater(
        VideoFrameExtractor(
                ffmpegExecutable: fake.path,
                processTimeout: const Duration(milliseconds: 100))
            .extract(video.path),
        throwsA(isA<MediaProcessTimedOut>()));
    expect(await video.exists(), isTrue);
    expect(await File('${frames.path}/complete.json').exists(), isFalse);
    expect((await frames.list().toList()).whereType<Directory>(), isEmpty);
    await expectLater(
        VideoAudioExtractor(
                ffprobeExecutable: fake.path,
                processTimeout: const Duration(milliseconds: 100))
            .extract(video.path),
        throwsA(isA<MediaProcessTimedOut>()));
    expect(await video.exists(), isTrue);
  });
  test('only completed frame output is reused for another timestamped event',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_complete_frames_');
    addTearDown(() => root.delete(recursive: true));
    final fake = File('${root.path}/decoder');
    await fake.writeAsString(
        '#!/bin/sh\nfor output do :; done\ndirectory="\${output%/*}"\nprintf frame > "\$directory/frame_01.jpg"\n');
    expect((await Process.run('/bin/chmod', ['+x', fake.path])).exitCode, 0);
    final video = File('${root.path}/original.mp4');
    await video.writeAsBytes([1, 2, 3]);
    final first = await VideoFrameExtractor(ffmpegExecutable: fake.path)
        .extract(video.path);
    expect(first.framePaths, hasLength(1));
    final reused = await const VideoFrameExtractor(
            ffmpegExecutable: '/must-not-spawn-for-complete-cache')
        .extract(video.path);
    expect(reused.framePaths, first.framePaths);
    expect(reused.sha256Digest, first.sha256Digest);
  });
}
