import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'package_knowledge.dart';
import 'knowledge_evidence_selection.dart';
import 'semantic_knowledge_scorer.dart';
import 'retrieval_topics.dart';

class LocalKnowledgeRetriever {
  LocalKnowledgeRetriever(this.knowledgeDirectory,
      {SemanticKnowledgeScorer? semanticScorer,
      SemanticKnowledgeScorer? secondInspectionScorer})
      : _semanticScorer =
            semanticScorer ?? const MacOSSemanticKnowledgeScorer(),
        _secondInspectionScorer = secondInspectionScorer;

  final Directory knowledgeDirectory;
  final SemanticKnowledgeScorer _semanticScorer;
  final SemanticKnowledgeScorer? _secondInspectionScorer;
  static final Map<String,
          ({String revision, Future<List<Map<String, dynamic>>> records})>
      _cache = {};
  static final _lexicalIndexes = Expando<_KnowledgeLexicalIndex>();

  Future<List<Map<String, Object?>>> retrieve(String query,
      {int limit = 5,
      bool? packageContentsQuery,
      bool includeSemanticScoring = true,
      String? currentQuestion}) async {
    final records = await _loadedRecords();
    return _retrieveFromRecords(query, records,
        limit: limit,
        packageContentsQuery: packageContentsQuery,
        includeSemanticScoring: includeSemanticScoring,
        currentQuestion: currentQuestion);
  }

  /// Index every approved customer-KB section, independently of a query or a
  /// customer's history. This runs ahead of second-inspection requests.
  Future<void> prepareSecondInspectionIndex() async {
    final scorer = _secondInspectionScorer;
    if (scorer is IndexedSemanticKnowledgeScorer) {
      await scorer.prepare(_secondInspectionRecords(await _loadedRecords()));
    }
  }

  List<Map<String, dynamic>> _secondInspectionRecords(
          List<Map<String, dynamic>> records) =>
      records.where((record) {
        if (!_isJdApplicable(record)) return false;
        if (record['status'] == 'active') return true;
        final source = (record['source_file'] ?? '').toString();
        // The source export also contains Flutter integration/configuration
        // notes. Those are never customer-answer evidence.
        return source.endsWith('_kb.md') ||
            p.basename(source) == 'customer_service_high_priority_issues.md';
      }).toList(growable: false);

  /// A real second retrieval path: no lexical cutoff, no 600-card candidate
  /// cap, and no small semantic bonus dominated by keyword scores. Confirmed
  /// model/category applicability is still enforced before answering.
  Future<List<Map<String, Object?>>> retrieveFullSemantic(String query,
      {int limit = 60}) async {
    final scorer = _secondInspectionScorer;
    if (scorer == null) {
      throw const SemanticSearchUnavailable(
          'Second-inspection semantic scorer is not configured.');
    }
    final eligible = await _eligibleSecondInspectionRecords(query);
    if (eligible.isEmpty) return const [];
    final scores = await scorer.score(retrievalQuestionText(query), eligible);
    if (eligible.any((r) => scores[r['id']?.toString()]?.isFinite != true)) {
      throw const SemanticSearchUnavailable(
          'Full semantic inspection returned incomplete scores.');
    }
    final ordered = eligible.toList()
      ..sort((a, b) =>
          scores[b['id'].toString()]!.compareTo(scores[a['id'].toString()]!));
    return ordered.take(limit).map(_compact).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> filterSecondInspectionEvidence(
      String query, List<Map<String, Object?>> candidates) async {
    final eligible = (await _eligibleSecondInspectionRecords(query))
        .map((r) => r['id'])
        .toSet();
    return candidates
        .where((r) => eligible.contains(r['id']))
        .toList(growable: false);
  }

  /// Expand only operation-relevant sections from already retrieved sources,
  /// and reserve applicable universal safety procedures before truncating.
  /// No new model call, customer history, or unverified model mapping is used.
  Future<List<Map<String, Object?>>> selectEvidence(
      String query, List<Map<String, Object?>> candidates,
      {required String currentQuestion, int limit = 16}) async {
    final eligible = await _eligibleSecondInspectionRecords(query);
    final ids = eligible.map((r) => r['id']).toSet();
    final filtered = candidates.where((r) => ids.contains(r['id'])).toList();
    final topics = retrievalTopics(currentQuestion);
    final sources = <String>{
      for (final r in filtered) ...[
        if (r['source_file'] != null) r['source_file'].toString(),
        ...(r['source_files'] as List<Object?>? ?? const [])
            .map((v) => v.toString()),
      ],
    };
    final expanded = <Map<String, Object?>>[
      ...filtered,
      if (topics.isNotEmpty)
        for (final record in eligible)
          if (sources.contains(record['source_file']) &&
              evidenceTopics(record).intersection(topics).isNotEmpty)
            _compact(record),
    ];
    final policies = topics.contains('safety')
        ? eligible
            .where(hasUniversalSafetyProcedure)
            .take(1)
            .map(_compact)
            .toList()
        : <Map<String, Object?>>[];
    return selectAnswerEvidence(
        question: currentQuestion,
        candidates: expanded,
        mandatory: policies,
        limit: limit);
  }

  Future<List<Map<String, dynamic>>> _eligibleSecondInspectionRecords(
      String query) async {
    final records = _secondInspectionRecords(await _loadedRecords());
    final modelLine = RegExp(r'^Exact product model:\s*(.+)$', multiLine: true)
            .firstMatch(query)
            ?.group(1) ??
        '';
    final models = RegExp(r'\b[a-z]{1,5}[ -]?\d{2,5}[a-z]{0,3}\b',
            caseSensitive: false)
        .allMatches(modelLine)
        .map((m) => m.group(0)!.toLowerCase().replaceAll(RegExp(r'[ -]'), ''))
        .toSet();
    final category =
        RegExp(r'^Required product category:\s*(.+)$', multiLine: true)
                .firstMatch(query)
                ?.group(1) ??
            '';
    final requiredFamilies = <String>{
      if (category.contains('thermal_label_printer')) 'thermal',
      if (category.contains('dot_matrix_printer')) 'dot_matrix',
      if (category.contains('attendance_machine')) 'attendance',
    };
    if (requiredFamilies.isEmpty && models.isNotEmpty) {
      // Only explicit, reviewed metadata can establish a model's family.
      // A model name mentioned in a filename/example is not classification.
      final reviewedFamilies = <String>{};
      for (final record in records.where((r) => r['status'] == 'active')) {
        if (knowledgeProductModels(record['models'])
            .intersection(models)
            .isEmpty) {
          continue;
        }
        switch (record['product_line']) {
          case 'thermal_printer':
            reviewedFamilies.add('thermal');
          case 'dot_matrix_printer':
            reviewedFamilies.add('dot_matrix');
          case 'attendance_machine':
            reviewedFamilies.add('attendance');
        }
      }
      if (reviewedFamilies.length == 1) {
        requiredFamilies.addAll(reviewedFamilies);
      }
    }
    return records.where((record) {
      final families = knowledgeProductFamilies(record);
      if (requiredFamilies.isNotEmpty &&
          families.isNotEmpty &&
          requiredFamilies.intersection(families).isEmpty) {
        return false;
      }
      final explicit = _explicitProductModels(record['models']);
      return models.isEmpty ||
          explicit.isEmpty ||
          explicit.intersection(models).isNotEmpty;
    }).toList(growable: false);
  }

  /// Opt-in, reviewed JD model facts remain visible regardless of phrasing.
  Future<List<Map<String, Object?>>> modelFactsFor(Set<String> models) async {
    if (models.isEmpty) return const [];
    final normalized = models
        .map((model) => model.toLowerCase().replaceAll(RegExp(r'[\s-]'), ''))
        .toSet();
    final records = await _loadedRecords();
    return records
        .where((record) =>
            _isJdApplicable(record) &&
            record['status'] == 'active' &&
            record['risk_level'] == 'low' &&
            record['auto_reply_allowed'] == true &&
            record['always_include_for_matching_models'] == true &&
            knowledgeProductModels(record['models'])
                .intersection(normalized)
                .isNotEmpty)
        .map(_compact)
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _loadedRecords() async {
    final key = knowledgeDirectory.absolute.path;
    final revision = await _knowledgeRevision();
    var cached = _cache[key];
    if (cached == null || cached.revision != revision) {
      cached = (revision: revision, records: _loadRecords());
      _cache[key] = cached;
    }
    final List<Map<String, dynamic>> records;
    try {
      records = await cached.records;
    } catch (_) {
      if (identical(_cache[key]?.records, cached.records)) _cache.remove(key);
      rethrow;
    }
    return records;
  }

  Future<List<Map<String, Object?>>> _retrieveFromRecords(
      String query, List<Map<String, dynamic>> records,
      {required int limit,
      bool? packageContentsQuery,
      bool includeSemanticScoring = true,
      String? currentQuestion}) async {
    final packageQuery =
        packageContentsQuery ?? hasPackageContentsIntent(query);
    final modelQuery = RegExp(r'^Exact product model:\s*(.+)$', multiLine: true)
            .firstMatch(query)
            ?.group(1) ??
        query;
    final queryModels =
        RegExp(r'\b[a-z]{1,5}[ -]?\d{2,5}[a-z]{0,3}\b', caseSensitive: false)
            .allMatches(modelQuery)
            .map((match) =>
                match.group(0)!.toLowerCase().replaceAll(RegExp(r'[ -]'), ''))
            .toSet();
    final packageFamilies = <String>{};
    final modelFamilies = <String>{};
    if (queryModels.isNotEmpty) {
      for (final record in records) {
        if (!_isJdApplicable(record)) continue;
        if (knowledgeProductModels(record['models'])
            .intersection(queryModels)
            .isNotEmpty) {
          // Exact-model metadata establishes the family. Mixed-family catalog
          // sections are not a reliable classification of an individual model.
          // A filename/example mentioning TP874 does not make it a needle
          // printer. Use reviewed model metadata, as the second pass does.
          final families = <String>{
            if (record['status'] == 'active')
              ...switch (record['product_line']) {
                'thermal_printer' => {'thermal'},
                'dot_matrix_printer' => {'dot_matrix'},
                'attendance_machine' => {'attendance'},
                _ => <String>{},
              },
          };
          if (families.length == 1) {
            modelFamilies.addAll(families);
            if (packageQuery) packageFamilies.addAll(families);
          }
        }
      }
    }
    final categoryLine =
        RegExp(r'^Required product category:\s*(.+)$', multiLine: true)
                .firstMatch(query)
                ?.group(1) ??
            '';
    final requiredFamilies = <String>{
      if (categoryLine.contains('dot_matrix_printer')) 'dot_matrix',
      if (categoryLine.contains('attendance_machine')) 'attendance',
      if (categoryLine.contains('thermal_label_printer')) 'thermal',
      if (categoryLine.isEmpty && modelFamilies.length == 1) ...modelFamilies,
    };
    final scored = <({double score, Map<String, dynamic> record})>[];
    final eligible = <Map<String, dynamic>>[];
    final expandedQuery =
        _expandEnglishTerms(query, packageQuery: packageQuery);
    final expandedQuestion = currentQuestion == null
        ? null
        : _expandEnglishTerms(currentQuestion, packageQuery: packageQuery);
    final index = _lexicalIndexes[records] ??= _KnowledgeLexicalIndex(records);
    final lexicalQuery =
        currentQuestion == null || currentQuestion.trim().isEmpty
            ? query
            : currentQuestion;
    // An unrecognised new question is not permission to revive an old topic.
    final requestedTopics = retrievalTopics(lexicalQuery);
    for (final record in records) {
      if (!_isJdApplicable(record)) continue;
      final families = knowledgeProductFamilies(record);
      if (requiredFamilies.isNotEmpty &&
          families.isNotEmpty &&
          families.intersection(requiredFamilies).isEmpty) {
        continue;
      }
      final explicitRecordModels = _explicitProductModels(record['models']);
      // Reject a different explicit model before semantic reranking can let
      // it occupy one of the small number of evidence slots. Generic family
      // labels such as "thermal printer" remain eligible for exact-model
      // questions because they often contain shared driver/setup guidance.
      if (queryModels.isNotEmpty &&
          explicitRecordModels.isNotEmpty &&
          explicitRecordModels.intersection(queryModels).isEmpty) {
        continue;
      }
      eligible.add(record);
      var score = _score(expandedQuery, record);
      if (expandedQuestion != null) {
        score += 3 * _score(expandedQuestion, record);
      }
      // Rare symptom terms outrank generic model/driver overlap. The existing
      // bounded semantic scorer remains optional; no new model call is added.
      score += 4 * index.score(lexicalQuery, record['id']?.toString() ?? '');
      if (requestedTopics.isNotEmpty) {
        final topics = retrievalTopics(retrievalRecordText(record));
        final overlap = topics.intersection(requestedTopics).length;
        score += overlap * 20;
        final primaryTopics = retrievalTopics(
            '${record['title'] ?? ''} ${record['issue'] ?? ''}');
        score += primaryTopics.intersection(requestedTopics).length * 12;
        if (requestedTopics.contains('print_speed') &&
            RegExp(r'\d+\s*`?\s*cps\b', caseSensitive: false)
                .hasMatch(retrievalRecordText(record))) {
          score += 100;
        }
        if (overlap == 0) score *= 0.5;
      }
      if (packageQuery && isPackageContentsRecord(record)) {
        final models = knowledgeProductModels(record['models']);
        final families = knowledgeProductFamilies(record);
        if (queryModels.isNotEmpty &&
            models.isNotEmpty &&
            models.intersection(queryModels).isEmpty) {
          continue;
        }
        if (packageFamilies.isNotEmpty &&
            families.isNotEmpty &&
            families.intersection(packageFamilies).isEmpty) {
          continue;
        }
        // Relevant family defaults must beat unrelated exact-model cards.
        // No package quantities are encoded here: the answer remains evidence.
        score += models.intersection(queryModels).isNotEmpty ? 110 : 100;
        if (record['status'] == 'active') score += 15;
        if (hasPackageQuantityIntent(query) &&
            hasPackageContentsEvidence(record, quantityRequired: true)) {
          score += 35;
        }
      }
      if (score > 0) scored.add((score: score, record: record));
    }
    scored.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) return byScore;
      return ((right.record['priority'] as num?) ?? 0)
          .compareTo((left.record['priority'] as num?) ?? 0);
    });
    // Curated cards and exact-model records are allowed into the semantic
    // pass even when the customer used different words from the dataset.
    // Source chunks still need lexical or exact-model support so the bounded
    // native scorer is not flooded with loosely related raw documentation.
    final lexicalCandidates =
        scored.take(limit > 35 ? limit : 35).toList(growable: false);
    final semanticPool = <Map<String, dynamic>>[];
    final semanticIds = <String>{};

    void addSemanticCandidate(Map<String, dynamic> record) {
      final id = record['id']?.toString() ?? '';
      if (id.isEmpty || !semanticIds.add(id)) return;
      semanticPool.add(record);
    }

    for (final item in lexicalCandidates) {
      addSemanticCandidate(item.record);
    }
    final semanticOnly = eligible.where((record) {
      final recordModels = _explicitProductModels(record['models']);
      final exactModel = queryModels.isNotEmpty &&
          recordModels.intersection(queryModels).isNotEmpty;
      return exactModel || record['status'] == 'active';
    }).toList(growable: false)
      ..sort((left, right) => ((right['priority'] as num?) ?? 0)
          .compareTo((left['priority'] as num?) ?? 0));
    for (final record in semanticOnly.take(600)) {
      addSemanticCandidate(record);
    }
    final semanticScores = includeSemanticScoring
        ? await _semanticScorer.score(
            expandedQuestion == null
                ? query
                : '$expandedQuestion ${queryModels.join(' ')}',
            semanticPool)
        : const <String, double>{};
    final hybrid = <({double score, Map<String, dynamic> record})>[
      for (final item in lexicalCandidates)
        (
          score: item.score +
              ((semanticScores[item.record['id']?.toString()] ?? 0) - 0.4)
                      .clamp(0.0, 1.0) *
                  30,
          record: item.record,
        ),
    ];
    // A strong semantic match can now rescue a reviewed record with no
    // lexical overlap. The threshold deliberately stays conservative because
    // these records will become customer-facing evidence.
    final hybridIds =
        hybrid.map((item) => item.record['id']?.toString() ?? '').toSet();
    for (final record in semanticPool) {
      final id = record['id']?.toString() ?? '';
      if (hybridIds.contains(id)) continue;
      final semantic = semanticScores[id] ?? 0;
      if (semantic < 0.68) continue;
      hybrid.add((
        score: 1 + (semantic - 0.4).clamp(0.0, 1.0) * 30,
        record: record,
      ));
    }
    hybrid.sort((left, right) {
      final byScore = right.score.compareTo(left.score);
      if (byScore != 0) return byScore;
      return ((right.record['priority'] as num?) ?? 0)
          .compareTo((left.record['priority'] as num?) ?? 0);
    });
    return hybrid.take(limit).map((item) => _compact(item.record)).toList();
  }

  Set<String> _explicitProductModels(Object? rawModels) {
    if (rawModels is! List) return const {};
    final pattern = RegExp(r'^[a-z]{1,5}\d{2,5}[a-z]{0,3}$');
    return rawModels
        .map((model) =>
            model.toString().toLowerCase().replaceAll(RegExp(r'[\s-]'), ''))
        .where(pattern.hasMatch)
        .toSet();
  }

  Future<String> _knowledgeRevision() async {
    final files = <File>[
      File(p.join(knowledgeDirectory.path, 'rag_cards',
          'customer_service_rag_cards.jsonl')),
      File(p.join(knowledgeDirectory.path, 'rag_cards', 'source_chunks.jsonl')),
    ];
    await for (final entry
        in knowledgeDirectory.list(recursive: true, followLinks: false)) {
      if (entry is File && _isCustomerKnowledgeMarkdown(entry)) {
        files.add(entry);
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    final metadata = await Future.wait(files.map((file) async {
      final stat = await file.stat();
      return '${file.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}:'
          '${stat.changed.microsecondsSinceEpoch}';
    }));
    return metadata.join('|');
  }

  Future<List<Map<String, Object?>>> mediaForRecords(
      List<Map<String, Object?>> records) async {
    final seen = <String>{};
    final media = <Map<String, Object?>>[];
    for (final record in records) {
      final recordId = record['id']?.toString() ?? '';
      final models = (record['models'] as List<Object?>? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false);
      for (final relativePath in _mediaPaths(record)) {
        if (!_isSupportedMedia(relativePath)) continue;
        final file = File(p.join(knowledgeDirectory.path, relativePath));
        if (!await file.exists()) continue;
        final absolutePath = file.absolute.path;
        if (!seen.add(absolutePath)) continue;
        media.add({
          'media_id': _mediaId(relativePath),
          'kind': _mediaKind(relativePath),
          'caption': p.basenameWithoutExtension(relativePath),
          'path': absolutePath,
          'record_id': recordId,
          'models': models,
        });
      }
    }
    return media;
  }

  Future<List<Map<String, dynamic>>> _loadRecords() async {
    final records = <Map<String, dynamic>>[];
    await _loadJsonLines(
      File(p.join(knowledgeDirectory.path, 'rag_cards',
          'customer_service_rag_cards.jsonl')),
      records,
      defaultPriority: 100,
      activeOnly: true,
    );
    await _loadJsonLines(
      File(p.join(knowledgeDirectory.path, 'rag_cards', 'source_chunks.jsonl')),
      records,
      defaultPriority: 40,
    );

    // The JD knowledge package also contains source evidence and READMEs.
    // Recursively include only explicitly named customer-KB Markdown files;
    // planning notes and unrelated documentation remain excluded.
    final markdownFiles = await knowledgeDirectory
        .list(recursive: true, followLinks: false)
        .where((entry) => entry is File && _isCustomerKnowledgeMarkdown(entry))
        .cast<File>()
        .toList();
    markdownFiles.sort((left, right) => left.path.compareTo(right.path));
    for (final file in markdownFiles) {
      final relativePath = p.relative(file.path, from: knowledgeDirectory.path);
      final content = await file.readAsString();
      records.addAll(_markdownRecords(relativePath, content));
    }
    return records;
  }

  bool _isCustomerKnowledgeMarkdown(File file) {
    final name = p.basename(file.path).toLowerCase();
    return name.endsWith('_kb.md') ||
        name == 'customer_service_high_priority_issues.md';
  }

  Future<void> _loadJsonLines(
    File file,
    List<Map<String, dynamic>> records, {
    required int defaultPriority,
    bool activeOnly = false,
  }) async {
    if (!await file.exists()) return;
    await for (final line in file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic> &&
          (!activeOnly || decoded['status'] == 'active')) {
        records.add(
            {...decoded, 'priority': decoded['priority'] ?? defaultPriority});
      }
    }
  }

  List<Map<String, dynamic>> _markdownRecords(
      String relativePath, String content) {
    if (content.trim().isEmpty) return const [];
    const maximumChunkLength = 5000;
    final sections = <({String title, String text})>[];
    var title = p.basenameWithoutExtension(relativePath);
    var buffer = StringBuffer();

    void saveSection() {
      final text = buffer.toString().trim();
      if (text.isNotEmpty) sections.add((title: title, text: text));
      buffer = StringBuffer();
    }

    for (final line in const LineSplitter().convert(content)) {
      final heading = RegExp(r'^#{1,6}\s+(.+?)\s*$').firstMatch(line);
      if (heading != null) {
        saveSection();
        title = heading.group(1)!.trim();
      }
      buffer.writeln(line);
    }
    saveSection();

    final records = <Map<String, dynamic>>[];
    var chunkIndex = 0;
    for (final section in sections) {
      for (var offset = 0; offset < section.text.length;) {
        final end = (offset + maximumChunkLength).clamp(0, section.text.length);
        final chunk = section.text.substring(offset, end).trim();
        offset = end;
        if (chunk.isEmpty) continue;
        chunkIndex += 1;
        final models = RegExp(r'\b[A-Z]{1,5}[ -]?\d{2,5}[A-Z]{0,3}\b')
            .allMatches(chunk.toUpperCase())
            .map((match) => match.group(0)!.replaceAll(RegExp(r'[ -]'), ''))
            .toSet()
            .toList(growable: false);
        records.add({
          'id': 'md_${_stableId('$relativePath:$chunkIndex')}',
          'type': 'source_markdown',
          'source_file': relativePath,
          'source_files': [relativePath],
          'title': section.title,
          'models': models,
          'intent': 'knowledge_source',
          'content': chunk,
          'priority': 20,
        });
      }
    }
    return records;
  }

  double _score(String searchQuery, Map<String, dynamic> record) {
    final normalizedQuery = _normalize(searchQuery);
    if (normalizedQuery.isEmpty) return 0;
    var score = 0.0;
    score += _termScore(searchQuery, record['keywords'], 8);
    score += _termScore(searchQuery, record['synonyms'], 7);
    score += _termScore(searchQuery, record['models'], 10);
    score += _textScore(normalizedQuery, record['issue']?.toString(), 4);
    score += _textScore(normalizedQuery, record['intent']?.toString(), 2);
    score += _textScore(normalizedQuery, record['id']?.toString(), 6);
    score += _textScore(normalizedQuery, record['title']?.toString(), 5);
    score += _textScore(normalizedQuery, record['content']?.toString(), 6);
    score += _termScore(searchQuery, record['source_files'], 3);
    if (_isMediaQuery(normalizedQuery) && _hasSupportedMedia(record)) {
      score += 20;
    }
    if (_isProductCatalogQuery(normalizedQuery)) {
      final intent = _normalize(record['intent']?.toString() ?? '');
      final id = _normalize(record['id']?.toString() ?? '');
      if (intent.contains('presale')) score += 30;
      if (id.contains('selling_points') || id.contains('recommend')) {
        score += 40;
      }
    }
    if (_isTechnicalQuery(normalizedQuery)) {
      final technicalText = _normalize([
        record['intent'],
        record['issue'],
        record['title'],
        record['reply_template'],
        record['content'],
      ].whereType<Object>().join(' '));
      for (final concept in const [
        ['driver', '驱动'],
        ['download', '下载'],
        ['install', '安装'],
        ['connect', '连接'],
        ['macos', '苹果'],
      ]) {
        if (concept.any(normalizedQuery.contains) &&
            concept.any(technicalText.contains)) {
          score += 14;
        }
      }
      final intent = _normalize(record['intent']?.toString() ?? '');
      if (const ['troubleshooting', 'tutorial', 'supportchannel']
          .any(intent.contains)) {
        score += 10;
      }
    }
    // Curated active cards carry reviewed reply policy, required slots, and
    // governed media links. Keep a genuinely matching card ahead of duplicate
    // source chunks/Markdown while allowing source-only exact matches through.
    if (record['status'] == 'active' && score >= 8) score += 30;
    return score;
  }

  bool _isProductCatalogQuery(String query) => const [
        'recommend',
        'suggest',
        'whichmodel',
        'whatmodel',
        'shouldibuy',
        'shouldwebuy',
        'needtobuy',
        'wanttobuy',
        'whatproducts',
        'whichproducts',
        'whatmodels',
        'whichmodels',
        'doyouhave',
        '推荐',
        '建议',
        '哪款',
        '买哪',
        '选哪',
      ].any(query.contains);

  bool _isTechnicalQuery(String query) => const [
        'driver',
        '驱动',
        'download',
        '下载',
        'install',
        '安装',
        'connect',
        '连接',
        'setup',
        '设置',
        'troubleshoot',
        '故障',
        '报错',
      ].any(query.contains);

  bool _isMediaQuery(String query) => const [
        'image',
        'images',
        'picture',
        'pictures',
        'photo',
        'photos',
        'show',
        'display',
        'view',
        'video',
        '图片',
        '照片',
        '展示',
        '看看',
        '参考',
        '外观',
        '截图',
        '视频',
      ].any(query.contains);

  bool _hasSupportedMedia(Map<String, dynamic> record) {
    return _mediaPaths(record).isNotEmpty;
  }

  List<String> _mediaPaths(Map<String, dynamic> record) {
    final paths = <String>{};
    final sources = record['source_files'];
    if (sources is List) {
      paths.addAll(sources.map((source) => source.toString()));
    }
    final visualEvidence = record['visual_evidence'];
    if (visualEvidence is Map) {
      paths.addAll(visualEvidence.values.map((source) => source.toString()));
    }
    return paths.where(_isSupportedMedia).toList(growable: false);
  }

  String _expandEnglishTerms(String query, {required bool packageQuery}) {
    final lower = query.toLowerCase();
    final terms = <String>[];
    if (packageQuery) {
      terms.add('包装清单 默认包装 随机配件');
      if (RegExp(r'\b(papers?|sheets?)\b|纸', caseSensitive: false)
          .hasMatch(query)) {
        terms.add('测试纸 赠纸 送多少纸 数量');
      }
      if (RegExp(r'\bcards?\b|卡', caseSensitive: false).hasMatch(query)) {
        terms.add('考勤卡 数量');
      }
    }
    for (final (pattern, translation) in const [
      (
        r'复写|联数|[一二三四五六七八九十\d]+\s*联|\b(?:carbon(?:less)?|multipart|multi[ -]?part)\b|\b(?:[1-9]|one|two|three|four|five|six)\s*(?:copies|layers|ply|parts)\b',
        '复写 联数 六联 1+5P'
      ),
      (r'\bdate\b', '日期'),
      (r'\byear\b', '年份'),
      (r'\btime\b', '时间'),
      (r'\bbattery\b', '电池'),
      (r'\bdrivers?\b', '驱动 下载 安装'),
      (r'\bdownload\b', '下载 驱动'),
      (r'\bconnect(?:ion|ing)?\b', '连接 安装'),
      (r'\bsetup\b', '设置 安装'),
      (r'\bmac(?:os|book)?\b', '苹果 macOS USB'),
      (r'\bandroid\b', '安卓 手机系统'),
      (r'\biphone\b|\bios\b', '苹果手机 手机系统'),
      (r'\bphones?\b|\bmobile\b', '手机 手机系统'),
      (r'\bapps?\b|\bgro+z+i+e+\b|\bsuyintong\b', '速印通 APP'),
      (r'\bcompatib(?:le|ility)\b|\bwork(?:s)? with\b', '兼容 支持'),
      (r'\bsupport(?:s|ed|ing)?\b', '支持'),
    ]) {
      if (RegExp(pattern).hasMatch(lower)) terms.add(translation);
    }
    return expandRetrievalTopics(
        terms.isEmpty ? query : '$query ${terms.join(' ')}');
  }

  double _termScore(String query, Object? rawTerms, double weight) {
    if (rawTerms is! List<Object?>) return 0;
    final normalizedQuery = _normalize(query);
    final lowerQuery = query.toLowerCase();
    var score = 0.0;
    for (final raw in rawTerms) {
      final term = _normalize(raw.toString());
      if (term.length < 2) continue;
      final shortAsciiTerm =
          term.length <= 3 && RegExp(r'^[a-z0-9]+$').hasMatch(term);
      final matches = shortAsciiTerm
          ? RegExp('(?:^|[^a-z0-9])${RegExp.escape(term)}(?:[^a-z0-9]|\$)')
              .hasMatch(lowerQuery)
          : normalizedQuery.contains(term);
      if (matches) score += weight;
    }
    return score;
  }

  double _textScore(String query, String? text, double weight) {
    if (text == null) return 0;
    final normalized = _normalize(text);
    if (normalized.isEmpty) return 0;
    if (query.contains(normalized) || normalized.contains(query)) return weight;
    final queryPairs = _pairs(query);
    final textPairs = _pairs(normalized);
    if (queryPairs.isEmpty || textPairs.isEmpty) return 0;
    final overlap = queryPairs.intersection(textPairs).length;
    return overlap / queryPairs.length * weight;
  }

  Set<String> _pairs(String value) => {
        for (var index = 0; index + 1 < value.length; index++)
          value.substring(index, index + 2),
      };

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  bool _isSupportedMedia(String path) => const {
        '.png',
        '.jpg',
        '.jpeg',
        '.webp',
        '.gif',
        '.mp4',
        '.mov',
      }.contains(p.extension(path).toLowerCase());

  String _mediaKind(String path) =>
      const {'.mp4', '.mov'}.contains(p.extension(path).toLowerCase())
          ? 'video'
          : 'image';

  String _mediaId(String relativePath) {
    // FNV-1a gives a deterministic ID without adding a crypto dependency.
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(relativePath)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return 'kb_${hash.toRadixString(16).padLeft(16, '0')}';
  }

  Map<String, Object?> _compact(Map<String, dynamic> record) => {
        // Keep governed structured facts (e.g. shift group_mapping/limits).
        // The former allowlist silently removed the actual setup instructions.
        for (final key in record.keys)
          if (!const {
                'keywords',
                'synonyms',
                'version',
                'package_version',
                'platforms',
                'current_platform',
                'resolution_ids',
                'always_include_for_matching_models'
              }.contains(key) &&
              _jdOnlyValue(record[key]) != null)
            key: _jdOnlyValue(record[key]),
      };

  bool _isJdApplicable(Map<String, dynamic> record) {
    final identity = [
      record['id'],
      record['title'],
      record['source_file'],
    ].whereType<Object>().join(' ');
    if (!_containsUnsupportedPlatform(identity)) return true;
    return RegExp(r'京东|\bjd\b|jingdong', caseSensitive: false)
        .hasMatch(identity);
  }

  Object? _jdOnlyValue(Object? value) {
    if (value is String) {
      if (!_containsUnsupportedPlatform(value)) return value;
      final kept = RegExp(r'[^。！？.!?；;\n]+[。！？.!?；;]?')
          .allMatches(value)
          .map((match) => match.group(0)!.trim())
          .where((segment) =>
              segment.isNotEmpty && !_containsUnsupportedPlatform(segment))
          .join(' ')
          .trim();
      return kept.isEmpty ? null : kept;
    }
    if (value is List) {
      final sanitized =
          value.map(_jdOnlyValue).whereType<Object>().toList(growable: false);
      return sanitized.isEmpty ? null : sanitized;
    }
    if (value is Map) {
      final sanitized = <String, Object?>{};
      for (final entry in value.entries) {
        if (_containsUnsupportedPlatform(entry.key.toString())) continue;
        final item = _jdOnlyValue(entry.value);
        if (item != null) sanitized[entry.key.toString()] = item;
      }
      return sanitized.isEmpty ? null : sanitized;
    }
    return value;
  }

  bool _containsUnsupportedPlatform(String value) => RegExp(
        r'微信|微信小程序|微信商城|wechat|weixin|天猫|淘宝|拼多多|抖音|闲鱼|小红书|快手|美团|tmall|taobao|pinduoduo|douyin|xiaohongshu|rednote|kuaishou|meituan|pddpic|tiktok\s*shop|amazon|ebay|aliexpress',
        caseSensitive: false,
      ).hasMatch(value);

  String _stableId(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

/// Cached per dataset revision, not per customer. Contains only approved KB
/// text; customer messages/media never enter this shared index.
class _KnowledgeLexicalIndex {
  _KnowledgeLexicalIndex(List<Map<String, dynamic>> records) {
    for (final record in records) {
      final id = record['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final tokens = _tokens(retrievalRecordText(record));
      final frequencies = <String, int>{};
      for (final token in tokens) {
        frequencies.update(token, (count) => count + 1, ifAbsent: () => 1);
      }
      _documents[id] = frequencies;
      _lengths[id] = tokens.length;
      for (final term in frequencies.keys) {
        _documentFrequency.update(term, (count) => count + 1,
            ifAbsent: () => 1);
      }
    }
    _averageLength = _lengths.isEmpty
        ? 1
        : _lengths.values.fold<int>(0, (sum, n) => sum + n) / _lengths.length;
  }

  final _documents = <String, Map<String, int>>{};
  final _documentFrequency = <String, int>{};
  final _lengths = <String, int>{};
  late final double _averageLength;

  static List<String> _tokens(String text) {
    final tokens = <String>[];
    for (final match in RegExp(r'[a-z0-9]+|[\u3400-\u9fff]+')
        .allMatches(text.toLowerCase())) {
      final term = match.group(0)!;
      if (RegExp(r'^[a-z0-9]').hasMatch(term)) {
        if (term.length > 1) tokens.add(term);
      } else {
        for (var i = 0; i + 1 < term.length; i++) {
          tokens.add(term.substring(i, i + 2));
        }
      }
    }
    return tokens;
  }

  double score(String query, String id) {
    final document = _documents[id];
    if (document == null || _averageLength <= 0) return 0;
    var total = 0.0;
    for (final term in _tokens(query).toSet()) {
      final tf = document[term] ?? 0;
      if (tf == 0) continue;
      final df = _documentFrequency[term] ?? 0;
      final idf = math.log(1 + (_documents.length - df + 0.5) / (df + 0.5));
      total += idf *
          (tf * 2.2) /
          (tf + 1.2 * (0.25 + 0.75 * (_lengths[id] ?? 0) / _averageLength));
    }
    return total;
  }
}
