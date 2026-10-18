import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'semantic_scoring.dart';

/// Only the official, pinned Q8 GGUF is accepted. No cloud, Ollama, Python,
/// automatic model downloads, or customer-history index is involved.
const qwenEmbeddingModel = 'Qwen3-Embedding-0.6B-Q8_0';
const qwenEmbeddingSha256 =
    '06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439';
const qwenEmbeddingDimensions = 1024;
const qwenRetrievalInstruction =
    'Given a customer service question, retrieve applicable product facts '
    'or instructions that answer the question.';

class _ModelDigestTask {
  const _ModelDigestTask(this.path);
  final String path;
  Future<String> call() async =>
      (await sha256.bind(File(path).openRead()).first).toString();
}

abstract class QwenEmbeddingBackend {
  Future<void> warmUp();
  Future<List<List<double>>> embed(List<String> texts);
  Future<void> close();
}

/// Owns one loopback-only native inference process. It cannot select an
/// externally running service or transmit a question to a remote endpoint.
class NativeQwenEmbeddingBackend implements QwenEmbeddingBackend {
  NativeQwenEmbeddingBackend({
    required this.modelFile,
    this.executable,
    this.startupTimeout = const Duration(seconds: 25),
    this.requestTimeout = const Duration(seconds: 12),
  });

  final File modelFile;
  final String? executable;
  final Duration startupTimeout;
  final Duration requestTimeout;
  Process? _process;
  Uri? _origin;
  Future<void>? _starting;
  bool _closed = false;

  @override
  Future<void> warmUp() => _ensureStarted();

  Future<void> _ensureStarted() async {
    if (_closed) {
      throw const SemanticSearchUnavailable('Qwen runtime is closed.');
    }
    if (_origin != null) return;
    final starting = _starting ??= _start();
    try {
      await starting;
    } on SemanticSearchUnavailable {
      rethrow;
    } on Object {
      throw const SemanticSearchUnavailable(
          'Qwen native runtime could not start.');
    } finally {
      if (identical(_starting, starting)) _starting = null;
    }
  }

  Future<void> _start() async {
    if (!await modelFile.exists() || await modelFile.length() != 639150592) {
      throw const SemanticSearchUnavailable(
          'Qwen Q8 model is missing. Run tools/download_qwen_embeddings.sh.');
    }
    // Verification is asynchronous and performed once per owned process.
    final digest = await Isolate.run(_ModelDigestTask(modelFile.path).call);
    if (digest != qwenEmbeddingSha256) {
      throw const SemanticSearchUnavailable(
          'Qwen Q8 model checksum is invalid.');
    }
    final server = await _findExecutable();
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final origin = Uri.parse('http://127.0.0.1:$port');
    // The tiny supervisor kills only its own child when this app exits. A
    // native model process must not be left behind after closing the app.
    final runtimeLibraryDirectory =
        Directory(p.normalize(p.join(p.dirname(server), '..', 'lib')));
    final process = await Process.start('/bin/sh', [
      '-c',
      r'''qwen_parent_pid=$1
shift
"$@" &
qwen_child_pid=$!
trap 'kill "$qwen_child_pid" 2>/dev/null || true' EXIT
trap 'exit 0' TERM INT
while kill -0 "$qwen_parent_pid" 2>/dev/null && kill -0 "$qwen_child_pid" 2>/dev/null; do
  /bin/sleep 1
done
''',
      'jd-qwen-runtime',
      '$pid',
      server,
      '--model',
      modelFile.path,
      '--alias',
      qwenEmbeddingModel,
      '--embedding',
      '--pooling',
      'last',
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
      '--ctx-size',
      '4096',
      '--batch-size',
      '2048',
      '--ubatch-size',
      '2048',
      '--parallel',
      '1',
      '--threads',
      '4',
      '--n-gpu-layers',
      '99',
      '--no-webui',
      '--log-disable',
    ], environment: {
      if (await File(p.join(runtimeLibraryDirectory.path, 'libggml-metal.so'))
          .exists())
        'GGML_BACKEND_PATH': runtimeLibraryDirectory.path,
    });
    _process = process;
    // Drain both pipes. Native logs must never be copied to a customer reply.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(process.exitCode.then((_) {
      if (identical(_process, process)) {
        _process = null;
        _origin = null;
      }
    }));
    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline) && identical(_process, process)) {
      if (_closed) break;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      try {
        final request = await client.getUrl(origin.resolve('/health'));
        final response =
            await request.close().timeout(const Duration(seconds: 1));
        await response.drain<void>();
        if (response.statusCode == HttpStatus.ok) {
          _origin = origin;
          return;
        }
      } on Object {
        // The model is still loading; this wait owns no JD UI lock.
      } finally {
        client.close(force: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    process.kill(ProcessSignal.sigterm);
    throw const SemanticSearchUnavailable(
        'Qwen native runtime did not become ready.');
  }

  Future<String> _findExecutable() async {
    final bundle = Directory(p.dirname(Platform.resolvedExecutable)).parent;
    for (final candidate in [
      if (executable != null) executable!,
      if (Platform.environment['JD_LLAMA_SERVER'] case final String path) path,
      p.join(bundle.path, 'Resources', 'jd_runtime', 'bin', 'llama-server'),
      '/opt/homebrew/bin/llama-server',
      '/usr/local/bin/llama-server',
    ]) {
      if (p.isAbsolute(candidate) && await File(candidate).exists()) {
        return candidate;
      }
    }
    throw const SemanticSearchUnavailable(
        'Native llama-server is missing. Install llama.cpp or bundle its runtime.');
  }

  @override
  Future<List<List<double>>> embed(List<String> texts) async {
    if (texts.isEmpty) return const [];
    await _ensureStarted();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      return await (() async {
        final request =
            await client.postUrl(_origin!.resolve('/v1/embeddings'));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({
          'model': qwenEmbeddingModel,
          'input': texts,
          'encoding_format': 'float',
        }));
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            throw const SemanticSearchUnavailable(
                'Qwen embedding response is too large.');
          }
        }
        if (response.statusCode != HttpStatus.ok) {
          throw SemanticSearchUnavailable(
              'Qwen embedding request failed (${response.statusCode}).');
        }
        final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final data = (value['data'] as List).cast<Map<String, dynamic>>();
        if (data.length != texts.length) {
          throw const SemanticSearchUnavailable(
              'Qwen returned incomplete embeddings.');
        }
        final ordered = List<List<double>?>.filled(texts.length, null);
        for (final item in data) {
          final index = item['index'];
          if (index is! int ||
              index < 0 ||
              index >= texts.length ||
              ordered[index] != null) {
            throw const SemanticSearchUnavailable(
                'Qwen returned invalid embedding indexes.');
          }
          ordered[index] = (item['embedding'] as List)
              .map((value) => (value as num).toDouble())
              .toList(growable: false);
        }
        return ordered.cast<List<double>>();
      })()
          .timeout(requestTimeout);
    } on SemanticSearchUnavailable {
      rethrow;
    } on Object {
      throw const SemanticSearchUnavailable(
          'Qwen embedding request failed or timed out.');
    } finally {
      // A timeout aborts the actual socket rather than leaving a queued request.
      client.close(force: true);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _process?.kill(ProcessSignal.sigterm);
    _process = null;
    _origin = null;
  }
}

/// Persistent, knowledge-only vectors. Customer queries are embedded in memory
/// and never written into this shared index. Disk entries are keyed by the
/// pinned model, document format, and complete chunk content, not record ID.
class QwenSemanticKnowledgeScorer implements IndexedSemanticKnowledgeScorer {
  QwenSemanticKnowledgeScorer(
      {required this.cacheDirectory, required this.backend});

  final Directory cacheDirectory;
  final QwenEmbeddingBackend backend;
  final Map<String, List<double>> _vectors = {};
  final Map<String, List<double>> _queries = {};
  Future<void>? _loading;
  Future<void>? _preparing;
  Object? lastPreparationError;
  int completedChunks = 0;
  int totalChunks = 0;
  static const _format = 1;

  File get _cacheFile =>
      File(p.join(cacheDirectory.path, 'qwen-q8-vectors.json'));

  static List<String> documentChunks(Map<String, dynamic> record) {
    final heading = [
      record['title'],
      record['issue'],
      record['product_line'],
      record['models'],
    ].whereType<Object>().join(' | ');
    final body = [
      for (final key in const [
        'reply_template',
        'reply_template_en',
        'content',
        'actions',
        'group_mapping',
        'limits',
        'usage_policy'
      ])
        if (record[key] != null)
          record[key] is String
              ? record[key].toString()
              : jsonEncode(record[key]),
    ].join('\n');
    final text = body.trim().isEmpty ? heading : body;
    final prefix = heading.length > 240 ? heading.substring(0, 240) : heading;
    final chunks = <String>[];
    // Index the whole procedure, including instructions beyond the old
    // 700-character semantic prefix. Overlap preserves boundary context.
    for (var start = 0; start < text.length;) {
      final end = math.min(start + 1200, text.length);
      chunks.add('$prefix\n${text.substring(start, end)}');
      if (end == text.length) break;
      start = end - 120;
    }
    return chunks;
  }

  String _key(String text) => sha256
      .convert(utf8.encode('$qwenEmbeddingSha256:$_format:$text'))
      .toString();

  List<double> _normalized(List<double> vector) {
    if (vector.length != qwenEmbeddingDimensions ||
        vector.any((n) => !n.isFinite)) {
      throw const SemanticSearchUnavailable('Qwen returned an invalid vector.');
    }
    final norm = math.sqrt(vector.fold<double>(0, (sum, n) => sum + n * n));
    if (norm <= 1e-12) {
      throw const SemanticSearchUnavailable('Qwen returned a zero vector.');
    }
    return vector.map((n) => n / norm).toList(growable: false);
  }

  Future<void> _load() => _loading ??= (() async {
        try {
          final value = jsonDecode(await _cacheFile.readAsString())
              as Map<String, dynamic>;
          if (value['format'] != _format ||
              value['model_sha256'] != qwenEmbeddingSha256 ||
              value['dimensions'] != qwenEmbeddingDimensions) {
            return;
          }
          for (final entry
              in (value['vectors'] as Map<String, dynamic>).entries) {
            try {
              final bytes = base64Decode(entry.value as String);
              if (bytes.length != qwenEmbeddingDimensions * 4) {
                continue;
              }
              final data = ByteData.sublistView(bytes);
              _vectors[entry.key] = _normalized(List.generate(
                  qwenEmbeddingDimensions,
                  (i) => data.getFloat32(i * 4, Endian.little)));
            } on Object {
              // Invalid cache entries are rebuilt, never used as evidence.
            }
          }
        } on Object {
          // Missing/corrupt cache is recoverable and is not a completed search.
        }
      })();

  Future<void> _persist() async {
    await cacheDirectory.create(recursive: true);
    final encoded = <String, String>{};
    for (final entry in _vectors.entries) {
      final bytes = ByteData(qwenEmbeddingDimensions * 4);
      for (var i = 0; i < qwenEmbeddingDimensions; i++) {
        bytes.setFloat32(i * 4, entry.value[i], Endian.little);
      }
      encoded[entry.key] = base64Encode(bytes.buffer.asUint8List());
    }
    final staging = File('${_cacheFile.path}.pending-$pid');
    await staging.writeAsString(
        jsonEncode({
          'format': _format,
          'model_sha256': qwenEmbeddingSha256,
          'dimensions': qwenEmbeddingDimensions,
          'vectors': encoded,
        }),
        flush: true);
    await staging.rename(_cacheFile.path);
  }

  @override
  Future<void> prepare(List<Map<String, dynamic>> records) async {
    if (_preparing case final Future<void> current) return current;
    final work = _prepare(records);
    _preparing = work;
    try {
      await work;
    } finally {
      if (identical(_preparing, work)) _preparing = null;
    }
  }

  Future<void> _prepare(List<Map<String, dynamic>> records) async {
    await _load();
    lastPreparationError = null;
    // Warm the native model ahead of a second inspection even when all
    // document vectors already exist on disk; the first query need not pay
    // checksum/model-load latency after the first reply attempt has failed.
    await backend.warmUp();
    final chunks = <String, String>{
      for (final record in records)
        for (final text in documentChunks(record)) _key(text): text,
    };
    totalChunks = chunks.length;
    completedChunks = chunks.keys.where(_vectors.containsKey).length;
    final missing =
        chunks.entries.where((e) => !_vectors.containsKey(e.key)).toList();
    try {
      for (var start = 0; start < missing.length; start += 4) {
        final batch =
            missing.sublist(start, math.min(start + 4, missing.length));
        final vectors = await backend.embed(batch.map((e) => e.value).toList());
        if (vectors.length != batch.length) {
          throw const SemanticSearchUnavailable(
              'Qwen index batch is incomplete.');
        }
        final normalized = vectors.map(_normalized).toList();
        for (var i = 0; i < batch.length; i++) {
          _vectors[batch[i].key] = normalized[i];
        }
        completedChunks += batch.length;
        if ((start + 4) % 128 == 0 || start + 4 >= missing.length) {
          await _persist();
        }
        // Yield between batches: indexing owns no UI/capture/generation lock.
        await Future<void>.delayed(Duration.zero);
      }
    } on Object catch (error) {
      lastPreparationError = error;
      rethrow;
    }
  }

  @override
  Future<Map<String, double>> score(
      String query, List<Map<String, dynamic>> records) async {
    if (query.trim().isEmpty || records.isEmpty) return const {};
    await _load();
    final documents = <String, List<String>>{
      for (final record in records)
        if ((record['id']?.toString() ?? '').isNotEmpty)
          record['id'].toString(): documentChunks(record).map(_key).toList(),
    };
    if (documents.values
        .expand((keys) => keys)
        .any((key) => !_vectors.containsKey(key))) {
      unawaited(prepare(records).catchError((Object _) {}));
      throw const SemanticSearchUnavailable(
          'Qwen knowledge index is preparing; this is not a no-answer result.');
    }
    // Preserve English, Chinese, model names, and the actual question.
    final text = 'Instruct: $qwenRetrievalInstruction\nQuery: ${query.trim()}';
    final queryKey = _key(text);
    var vector = _queries[queryKey];
    if (vector == null) {
      final result = await backend.embed([text]);
      if (result.length != 1) {
        throw const SemanticSearchUnavailable(
            'Qwen query embedding is missing.');
      }
      vector = _normalized(result.single);
      _queries[queryKey] = vector;
      if (_queries.length > 64) _queries.remove(_queries.keys.first);
    }
    final result = <String, double>{};
    for (final entry in documents.entries) {
      var best = -1.0;
      for (final key in entry.value) {
        final document = _vectors[key]!;
        var dot = 0.0;
        for (var i = 0; i < vector.length; i++) {
          dot += vector[i] * document[i];
        }
        best = math.max(best, dot);
      }
      result[entry.key] = best;
    }
    return result;
  }

  Future<void> close() => backend.close();
}
