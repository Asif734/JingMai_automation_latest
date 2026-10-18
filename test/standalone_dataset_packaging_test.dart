import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tools/package_standalone_macos.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory destination;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_dataset_bundle_');
    source = await Directory('${root.path}/dataset').create();
    destination = Directory('${root.path}/bundle/dataset');
  });
  tearDown(() => root.delete(recursive: true));

  test('includes all dataset formats and preserves nested paths and bytes',
      () async {
    const paths = [
      'product_kb.md',
      'rag_cards/source_chunks.jsonl',
      'rag_index/index.json',
      'handover/runtime_prompt.txt',
      'sources/manual.pdf',
      'sources/原始文档.docx',
      'assets/images/photo.png',
      'assets/videos/tutorial.mp4',
    ];
    for (var i = 0; i < paths.length; i++) {
      final file = File('${source.path}/${paths[i]}');
      await file.create(recursive: true);
      await file.writeAsBytes([i, 0, 255, 1, 2]);
    }
    await File('${source.path}/.DS_Store').writeAsString('Finder metadata');
    final manifest = await copyCompleteDataset(source, destination);
    expect(manifest.map((item) => item['path']), unorderedEquals(paths));
    expect(await File('${destination.path}/.DS_Store').exists(), isFalse);
    for (final item in manifest) {
      final original =
          await File('${source.path}/${item['path']}').readAsBytes();
      final copied =
          await File('${destination.path}/${item['path']}').readAsBytes();
      expect(copied, original);
      expect(item['size_bytes'], original.length);
      expect(item['sha256'], sha256.convert(original).toString());
    }
  });

  test('rejects symbolic links before copying any dataset content', () async {
    final external = File('${root.path}/private-customer-history.json');
    await external.writeAsString('not dataset evidence');
    await Link('${source.path}/external.json').create(external.path);
    await expectLater(
        copyCompleteDataset(source, destination), throwsA(isA<StateError>()));
    expect(await destination.exists(), isFalse);
  });

  test('rejects overlapping source and destination', () async {
    for (final target in [source, Directory('${source.path}/nested'), root]) {
      await expectLater(
          copyCompleteDataset(source, target), throwsA(isA<ArgumentError>()));
    }
  });

  test('customer snapshot excludes downloaded Qwen models and vector caches',
      () async {
    await File('${source.path}/customer.json').writeAsString('{}');
    final model = File('${source.path}/qwen_embeddings/model.gguf');
    await model.create(recursive: true);
    await model.writeAsBytes([1, 2, 3]);
    final cache = File('${source.path}/qwen_embeddings/index/vectors.json');
    await cache.create(recursive: true);
    await cache.writeAsString('{}');
    final manifest = await snapshotAndCopyData(source, destination);
    expect(manifest.map((item) => item['path']), ['customer.json']);
    expect(await Directory('${destination.path}/qwen_embeddings').exists(),
        isFalse);
  });

  test('native Qwen packaging resolves recorded loader-relative runpaths',
      () async {
    final executable = '${root.path}/cellar/bin/llama-server';
    final library = File('${root.path}/cellar/lib/libllama.dylib');
    await library.create(recursive: true);
    final paths = machORunPaths(executable,
        'cmd LC_RPATH\ncmdsize 32\npath @loader_path/../lib (offset 12)');
    expect(
        await resolveMachODependency('@rpath/libllama.dylib',
            source: executable, runPaths: paths),
        library.path);
    await expectLater(
        resolveMachODependency('@rpath/not-present.dylib',
            source: executable, runPaths: paths),
        throwsA(isA<StateError>()));
  });
}
