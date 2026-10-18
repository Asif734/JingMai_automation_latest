import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

// Packages the complete knowledge dataset, a stable snapshot of the current
// customer state, and media tools. Auth/environment files, the source
// repository, and the Codex executable are not distributed.
Future<void> main(List<String> args) async {
  if (args.length != 1 || !args.single.endsWith('.app')) {
    throw ArgumentError(
        'Usage: dart run tools/package_standalone_macos.dart <app>');
  }
  final project = Directory.current.absolute;
  final app = Directory(args.single).absolute;
  if (!await File(p.join(app.path, 'Contents', 'Info.plist')).exists()) {
    throw StateError('Built app is missing: ${app.path}');
  }
  final runtime =
      Directory(p.join(app.path, 'Contents', 'Resources', 'jd_runtime'));
  // Clear only the validated, generated runtime directory inside this app.
  if (await runtime.exists()) await runtime.delete(recursive: true);
  await runtime.create(recursive: true);
  const knowledgeName = '格志京东客服知识库-2026-10-04';
  final sourceKnowledge = Directory(p.join(project.path, knowledgeName));
  final packagedKnowledge = Directory(p.join(runtime.path, knowledgeName));
  final knowledgeFiles =
      await copyCompleteDataset(sourceKnowledge, packagedKnowledge);
  final packagedData = Directory(p.join(runtime.path, 'initial_data'));
  final dataFiles = await snapshotAndCopyData(
      Directory(p.join(project.path, 'data')), packagedData);
  final cards = Directory(p.join(packagedKnowledge.path, 'rag_cards'));
  final workspace = Directory(p.join(runtime.path, 'codex_workspace'));
  await workspace.create();
  for (final name in [
    'AGENTS.md',
    'reply.schema.json',
    'search_plan.schema.json'
  ]) {
    await File(p.join(project.path, 'codex_workspace', name))
        .copy(p.join(workspace.path, name));
  }
  for (final required in [
    p.join(cards.path, 'customer_service_rag_cards.jsonl'),
    p.join(cards.path, 'source_chunks.jsonl'),
    p.join(packagedKnowledge.path, 'product_model_feature_catalog_kb.md'),
  ]) {
    if (!await File(required).exists()) {
      throw StateError('Missing runtime evidence: $required');
    }
  }

  final bin = Directory(p.join(runtime.path, 'bin'));
  final libs = Directory(p.join(runtime.path, 'lib'));
  await bin.create();
  await libs.create();
  final originals = <String, String>{}; // install name -> packaged file
  final realTargets = <String, String>{};
  final dependencyEdges = <String, Map<String, String>>{};
  final cellarRoots = <String>{};
  final queue = <String>[];
  final inheritedRunPaths = <String>{};

  Future<String> copyBinary(String source, {bool executable = false}) async {
    final known = originals[source];
    if (known != null) return known;
    final real = await File(source).resolveSymbolicLinks();
    if (realTargets[real] case final String target) {
      originals[source] = target;
      return target;
    }
    final target =
        p.join(executable ? bin.path : libs.path, p.basename(source));
    if (realTargets.values.contains(target)) {
      throw StateError('Conflicting bundled library name: $target');
    }
    await File(real).copy(target);
    await run('chmod', ['u+w', target]);
    originals[source] = target;
    realTargets[real] = target;
    queue.add(real);
    final parts = p.split(real);
    final cellar = parts.indexOf('Cellar');
    if (cellar >= 0 && parts.length > cellar + 2) {
      cellarRoots.add(p.joinAll(parts.take(cellar + 3)));
    }
    if (p.basename(real).startsWith('libggml.')) {
      // Current llama.cpp loads CPU/Metal/Accelerate backends dynamically;
      // they do not appear in `otool -L` and must travel with the runtime.
      final plugins = Directory(p.join(p.dirname(p.dirname(real)), 'libexec'));
      if (await plugins.exists()) {
        await for (final plugin in plugins.list(followLinks: false)) {
          if (plugin is File &&
              RegExp(r'^libggml-(?:cpu|metal|blas).*\.so$')
                  .hasMatch(p.basename(plugin.path))) {
            await copyBinary(plugin.path);
          }
        }
      }
    }
    return target;
  }

  for (final name in ['ffmpeg', 'ffprobe', 'llama-server']) {
    final configured = Platform.environment[name == 'llama-server'
        ? 'JD_LLAMA_SERVER'
        : 'JD_${name.toUpperCase()}'];
    final candidates = [
      if (configured != null) configured,
      '/opt/homebrew/bin/$name',
      '/usr/local/bin/$name',
    ];
    String? source;
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        source = candidate;
        break;
      }
    }
    if (source == null) {
      throw StateError(
          '$name is needed on the build Mac for standalone media/Qwen support.');
    }
    await copyBinary(source, executable: true);
    final real = await File(source).resolveSymbolicLinks();
    inheritedRunPaths
        .addAll(machORunPaths(real, await run('otool', ['-l', real])));
  }
  for (var i = 0; i < queue.length; i++) {
    final source = queue[i];
    final target = realTargets[source]!;
    final edges = <String, String>{};
    final listing = await run('otool', ['-L', source]);
    final runPaths = [
      ...machORunPaths(source, await run('otool', ['-l', source])),
      ...inheritedRunPaths,
    ];
    final dependencyLines = const LineSplitter()
        .convert(listing)
        .skip(target.endsWith('.dylib') ? 2 : 1);
    for (final line in dependencyLines) {
      final dependency = line.trim().split(' (').first;
      if (dependency.startsWith('/System/Library/') ||
          dependency.startsWith('/usr/lib/')) {
        continue;
      }
      final resolved = await resolveMachODependency(dependency,
          source: source, runPaths: runPaths);
      final dependencyReal = await File(resolved).resolveSymbolicLinks();
      if (dependencyReal == source) {
        continue; // dylib install ID, not a dependency
      }
      edges[dependency] = await copyBinary(resolved);
    }
    dependencyEdges[target] = edges;
  }
  var minimumMacOS = '15.0';
  for (final entry in realTargets.entries) {
    final target = entry.value;
    final architectures = await run('lipo', ['-archs', target]);
    if (!architectures.split(RegExp(r'\s+')).contains('arm64')) {
      throw StateError(
          'Bundled video tool is not Apple Silicon compatible: $target');
    }
    final commands = await run('otool', ['-l', target]);
    final minimumVersions = [
      ...RegExp(r'\bminos (\d+\.\d+(?:\.\d+)?)').allMatches(commands),
      ...RegExp(
              r'cmd LC_VERSION_MIN_MACOS\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)')
          .allMatches(commands),
    ];
    for (final match in minimumVersions) {
      final version = match.group(1)!;
      if (newerVersion(version, minimumMacOS)) minimumMacOS = version;
    }
    for (final edge in dependencyEdges[target]!.entries) {
      await run('install_name_tool', [
        '-change',
        edge.key,
        '@loader_path/${p.relative(edge.value, from: p.dirname(target))}',
        target
      ]);
    }
    if (target.endsWith('.dylib')) {
      await run(
          'install_name_tool', ['-id', '@rpath/${p.basename(target)}', target]);
    }
    await run('codesign', ['--force', '--sign', '-', target]);
  }
  final notices = Directory(p.join(runtime.path, 'third_party_notices'));
  await notices.create();
  for (final root in cellarRoots) {
    final destination = Directory(p.join(
        notices.path, '${p.basename(p.dirname(root))}-${p.basename(root)}'));
    await destination.create();
    await for (final entry in Directory(root).list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is File &&
          (name.toUpperCase().startsWith('LICENSE') ||
              name.toUpperCase().startsWith('COPYING') ||
              name == 'INSTALL_RECEIPT.json' ||
              name == 'sbom.spdx.json')) {
        await entry.copy(p.join(destination.path, name));
      }
    }
    final formulas = Directory(p.join(root, '.brew'));
    if (await formulas.exists()) {
      await for (final entry in formulas.list(followLinks: false)) {
        if (entry is File && entry.path.endsWith('.rb')) {
          await entry.copy(p.join(destination.path, p.basename(entry.path)));
        }
      }
    }
  }
  await run('/usr/libexec/PlistBuddy', [
    '-c',
    'Set :LSMinimumSystemVersion $minimumMacOS',
    p.join(app.path, 'Contents', 'Info.plist')
  ]);
  await File(p.join(runtime.path, 'package_manifest.json'))
      .writeAsString(const JsonEncoder.withIndent('  ').convert({
    'app_name': 'JD Automation Standalone',
    'bundle_id': 'com.grozziie.jdAutomation.standalone',
    'architecture': 'arm64',
    'minimum_macos': minimumMacOS,
    'knowledge': knowledgeName,
    'knowledge_file_count': knowledgeFiles.length,
    'knowledge_files': knowledgeFiles,
    'initial_data_file_count': dataFiles.length,
    'initial_data_files': dataFiles,
    'initial_data_installation':
        'Copied to Application Support on first launch only; existing data is never overwritten.',
    'external_dependency': 'Installed, authenticated Codex CLI and JD Jingmai',
    'bundled_media_binaries': realTargets.values
        .map((s) => p.relative(s, from: runtime.path))
        .toList(),
    'includes': ['customer data', 'media', 'logs', 'Codex sessions'],
    'excludes': ['credentials', 'environment files', 'source repository'],
  }));
  for (final name in ['ffmpeg', 'ffprobe']) {
    await run(p.join(bin.path, name), ['-version']);
  }
  stdout.writeln(
      'Packaged ${knowledgeFiles.length} verified knowledge files, ${dataFiles.length} customer-data files, and ${realTargets.length} media binaries; macOS $minimumMacOS+.');
}

List<String> machORunPaths(String source, String loadCommands) => [
      for (final match
          in RegExp(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)')
              .allMatches(loadCommands))
        if (match.group(1)!.startsWith('@loader_path/'))
          p.normalize(p.join(p.dirname(source), match.group(1)!.substring(13)))
        else if (p.isAbsolute(match.group(1)!))
          match.group(1)!,
    ];

Future<String> resolveMachODependency(String dependency,
    {required String source, required Iterable<String> runPaths}) async {
  final candidates = [
    if (p.isAbsolute(dependency)) dependency,
    if (dependency.startsWith('@loader_path/'))
      p.normalize(p.join(p.dirname(source), dependency.substring(13))),
    if (dependency.startsWith('@rpath/'))
      for (final path in runPaths) p.join(path, dependency.substring(7)),
  ];
  for (final path in candidates) {
    if (await File(path).exists()) return path;
  }
  throw StateError('Unresolved non-system dependency: $dependency in $source');
}

/// Takes a stable build-time snapshot before hashing/package copy. The live
/// review app may append logs while packaging, so source files are copied once
/// into a temporary directory. SQLite uses its online backup command rather
/// than a byte copy, yielding a consistent database even if it is open.
Future<List<Map<String, Object>>> snapshotAndCopyData(
    Directory source, Directory destination) async {
  if (!await source.exists()) {
    throw StateError('Customer data directory is missing: ${source.path}');
  }
  final snapshot = await Directory.systemTemp.createTemp('jd_data_snapshot_');
  try {
    final entries =
        await source.list(recursive: true, followLinks: false).toList();
    for (final entry in entries) {
      if (entry is! File && entry is! Directory) {
        throw StateError('Unsupported customer-data entry: ${entry.path}');
      }
    }
    for (final entry in entries) {
      final relative = p.relative(entry.path, from: source.path);
      // Downloaded model weights and derived embedding vectors are local
      // runtime data, not part of the customer-state snapshot/app download.
      if (p.split(relative).first == 'qwen_embeddings') continue;
      if (p.basename(relative) == '.DS_Store' ||
          relative == 'jd_automation.sqlite3') {
        continue;
      }
      final target = p.join(snapshot.path, relative);
      if (entry is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entry is File) {
        await File(target).parent.create(recursive: true);
        await entry.copy(target);
      }
    }
    final sourceDatabase = File(p.join(source.path, 'jd_automation.sqlite3'));
    if (await sourceDatabase.exists()) {
      final snapshotDatabase = p.join(snapshot.path, 'jd_automation.sqlite3');
      final escaped = snapshotDatabase.replaceAll("'", "''");
      await run('sqlite3', [sourceDatabase.path, ".backup '$escaped'"]);
      final integrity =
          (await run('sqlite3', [snapshotDatabase, 'PRAGMA integrity_check;']))
              .trim();
      if (integrity != 'ok') {
        throw StateError(
            'Customer database snapshot failed integrity check: $integrity');
      }
    }
    return await copyCompleteDataset(snapshot, destination);
  } finally {
    if (await snapshot.exists()) await snapshot.delete(recursive: true);
  }
}

/// Copy every dataset file, preserving relative paths and verifying bytes.
/// Finder metadata is not evidence. Reject links instead of shipping references
/// to files outside the dataset or accidentally copying unrelated local state.
Future<List<Map<String, Object>>> copyCompleteDataset(
    Directory source, Directory destination) async {
  final sourcePath = p.normalize(source.absolute.path);
  final destinationPath = p.normalize(destination.absolute.path);
  if (sourcePath == destinationPath ||
      p.isWithin(sourcePath, destinationPath) ||
      p.isWithin(destinationPath, sourcePath)) {
    throw ArgumentError('Dataset source and destination must be separate.');
  }
  final entries =
      await source.list(recursive: true, followLinks: false).toList();
  for (final entry in entries) {
    if (entry is! File && entry is! Directory) {
      throw StateError('Unsupported dataset entry: ${entry.path}');
    }
  }
  final files = entries
      .whereType<File>()
      .where((file) => p.basename(file.path) != '.DS_Store')
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  await destination.create(recursive: true);
  final manifest = <Map<String, Object>>[];
  for (final sourceFile in files) {
    final relativePath =
        p.relative(sourceFile.path, from: source.absolute.path);
    final destinationFile = File(p.join(destinationPath, relativePath));
    await destinationFile.parent.create(recursive: true);
    final digest = await sha256.bind(sourceFile.openRead()).first;
    await sourceFile.copy(destinationFile.path);
    if (await sha256.bind(destinationFile.openRead()).first != digest) {
      throw StateError('Dataset copy failed verification: $relativePath');
    }
    manifest.add({
      'path': relativePath,
      'size_bytes': await destinationFile.length(),
      'sha256': digest.toString(),
    });
  }
  return manifest;
}

bool newerVersion(String a, String b) {
  final left = a.split('.').map(int.parse).toList();
  final right = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l > r;
  }
  return false;
}

Future<String> run(String command, List<String> args) async {
  final result = await Process.run(command, args);
  if (result.exitCode != 0) {
    throw StateError('$command failed (${result.exitCode}): ${result.stderr}');
  }
  return result.stdout.toString();
}
