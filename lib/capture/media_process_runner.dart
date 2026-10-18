import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A timeout must terminate the decoder, not just abandon its Dart future.
class MediaProcessRunner {
  const MediaProcessRunner();

  Future<ProcessResult> run(String executable, List<String> arguments,
      {required Duration timeout}) async {
    final process = await Process.start(executable, arguments);
    final output = <int>[];
    final errors = <int>[];
    void collect(List<int> destination, List<int> bytes) {
      final remaining = 1024 * 1024 - destination.length;
      if (remaining > 0) destination.addAll(bytes.take(remaining));
    }

    final stdout = process.stdout.listen((bytes) => collect(output, bytes));
    final stderr = process.stderr.listen((bytes) => collect(errors, bytes));
    final outputDone = stdout.asFuture<void>();
    final errorDone = stderr.asFuture<void>();
    // Observe stream errors even when process termination takes the timeout path.
    unawaited(outputDone.catchError((Object _) {}));
    unawaited(errorDone.catchError((Object _) {}));
    try {
      await process.stdin.close();
      final exit = await process.exitCode.timeout(timeout);
      await Future.wait([outputDone, errorDone])
          .timeout(const Duration(seconds: 1));
      return ProcessResult(
          process.pid,
          exit,
          utf8.decode(output, allowMalformed: true),
          utf8.decode(errors, allowMalformed: true));
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(milliseconds: 250));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          // Do not retain the application worker even if OS reaping is slow.
        }
      }
      throw MediaProcessTimedOut(executable, timeout, pid: process.pid);
    } finally {
      await stdout.cancel();
      await stderr.cancel();
    }
  }
}

class MediaProcessTimedOut implements Exception {
  const MediaProcessTimedOut(this.executable, this.timeout, {this.pid});
  final String executable;
  final Duration timeout;
  final int? pid;
  @override
  String toString() =>
      'Media process timed out after ${timeout.inSeconds}s: $executable';
}
