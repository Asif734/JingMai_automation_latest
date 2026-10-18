import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../runtime/app_runtime.dart';
import 'media_process_runner.dart';

class ExtractedVideoFrames {
  const ExtractedVideoFrames({
    required this.videoPath,
    required this.sha256Digest,
    required this.framePaths,
  });

  final String videoPath;
  final String sha256Digest;
  final List<String> framePaths;
}

class VideoFrameExtractor {
  const VideoFrameExtractor(
      {this.ffmpegExecutable,
      this.processTimeout = const Duration(seconds: 15)});

  static const maximumFrames = 20;
  final String? ffmpegExecutable;
  final Duration processTimeout;

  List<String> buildArguments(String inputPath, String outputPattern) => [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-i',
        inputPath,
        '-vf',
        'fps=1',
        '-frames:v',
        '$maximumFrames',
        '-q:v',
        '2',
        outputPattern,
      ];

  Future<ExtractedVideoFrames> extract(String videoPath) async {
    final video = File(videoPath);
    if (!await video.exists()) {
      throw VideoFrameExtractionException(
          'Downloaded video is missing: $videoPath');
    }
    final digest = (await sha256.bind(video.openRead()).first).toString();
    final frameDirectory = Directory(
      p.join(video.parent.path, 'frames_${digest.substring(0, 16)}'),
    );
    await frameDirectory.create(recursive: true);
    final manifest = File(p.join(frameDirectory.path, 'complete.json'));
    List<String> existing = [];
    if (await manifest.exists()) {
      try {
        final data = jsonDecode(await manifest.readAsString()) as Map;
        final paths = (data['frames'] as List).cast<String>();
        if (data['sha256'] == digest &&
            paths.isNotEmpty &&
            paths.every((path) => p.isWithin(frameDirectory.path, path)) &&
            (await Future.wait(paths.map((path) => File(path).exists())))
                .every((v) => v)) {
          existing = paths;
        }
      } on Object {
        // A partial/interrupted run is not a complete reusable frame cache.
      }
    }
    if (existing.isNotEmpty) {
      return ExtractedVideoFrames(
        videoPath: videoPath,
        sha256Digest: digest,
        framePaths: existing.take(maximumFrames).toList(growable: false),
      );
    }

    final executable = ffmpegExecutable ?? await _findFfmpeg();
    final staging = await frameDirectory.createTemp('work_');
    try {
      final pattern = p.join(staging.path, 'frame_%02d.jpg');
      final result = await const MediaProcessRunner().run(
          executable, buildArguments(videoPath, pattern),
          timeout: processTimeout);
      if (result.exitCode != 0) {
        throw VideoFrameExtractionException(
          'FFmpeg failed to sample the customer video: ${result.stderr}',
        );
      }
      final frames = await _frames(staging);
      if (frames.isEmpty) {
        throw const VideoFrameExtractionException(
          'The customer video contained no decodable frames.',
        );
      }
      final temporary = File('${manifest.path}.tmp');
      await temporary.writeAsString(
          jsonEncode({'sha256': digest, 'frames': frames}),
          flush: true);
      await temporary.rename(manifest.path);
      return ExtractedVideoFrames(
        videoPath: videoPath,
        sha256Digest: digest,
        framePaths: frames.take(maximumFrames).toList(growable: false),
      );
    } catch (_) {
      // Only remove this invocation's newly created partial output.
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<List<String>> _frames(Directory directory) async {
    final paths = await directory
        .list()
        .where((entry) =>
            entry is File &&
            RegExp(r'^frame_\d{2}\.jpg$').hasMatch(p.basename(entry.path)))
        .map((entry) => entry.path)
        .toList();
    paths.sort();
    return paths;
  }

  Future<String> _findFfmpeg() async {
    final bundled = await AppRuntime.bundledTool('ffmpeg');
    if (bundled != null) return bundled;
    for (final candidate in const [
      '/opt/homebrew/bin/ffmpeg',
      '/usr/local/bin/ffmpeg',
      '/usr/bin/ffmpeg',
    ]) {
      if (await File(candidate).exists()) return candidate;
    }
    throw const VideoFrameExtractionException(
      'FFmpeg is required for customer-video analysis but was not found.',
    );
  }
}

class VideoFrameExtractionException implements Exception {
  const VideoFrameExtractionException(this.message);
  final String message;

  @override
  String toString() => message;
}
