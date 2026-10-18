import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'semantic_scoring.dart';
export 'semantic_scoring.dart';

/// Uses macOS NaturalLanguage sentence embeddings. The lexical retriever
/// remains authoritative when the native service is unavailable or slow.
class MacOSSemanticKnowledgeScorer implements SemanticKnowledgeScorer {
  const MacOSSemanticKnowledgeScorer();

  static const _channel =
      MethodChannel('com.grozziie.jdAutomation/semanticRetrieval');

  @override
  Future<Map<String, double>> score(
      String query, List<Map<String, dynamic>> records) async {
    if (!Platform.isMacOS || records.isEmpty) return const {};
    final semanticQuery = _semanticQuery(query);
    if (semanticQuery.isEmpty) return const {};
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'score',
        {
          'query': semanticQuery,
          'records': [
            for (final record in records)
              {
                'id': record['id']?.toString() ?? '',
                'text': _recordText(record),
              },
          ],
        },
      ).timeout(const Duration(milliseconds: 1500));
      if (response == null) return const {};
      return {
        for (final entry in response.entries)
          if (entry.value is num) entry.key: (entry.value as num).toDouble(),
      };
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    } on TimeoutException {
      return const {};
    }
  }

  String _recordText(Map<String, dynamic> record) {
    final parts = <String>[
      for (final key in const [
        'issue',
        'title',
        'product_line',
        'reply_template'
      ])
        if (record[key] != null) record[key].toString(),
      for (final key in const ['keywords', 'synonyms', 'models'])
        if (record[key] is List) (record[key] as List).join(' '),
      if (record['content'] != null) record['content'].toString(),
    ];
    final text = parts.join('。');
    return text.length > 700 ? text.substring(0, 700) : text;
  }

  String _semanticQuery(String query) {
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(query)) {
      return query.length > 500 ? query.substring(query.length - 500) : query;
    }
    final lower = query.toLowerCase();
    final terms = <String>[];
    for (final (pattern, translation) in const [
      (r'\bthermal printer\b', '热敏打印机'),
      (r'\bdot matrix\b', '针式打印机'),
      (r'\battendance\b|\btime clock\b', '考勤机'),
      (r'\bmodels?\b|\bmodel[ ._-]*list\b', '型号'),
      (r'\blist\b|\bwhat (?:are|do)\b', '清单'),
      (r'\bshipping labels?\b', '快递面单'),
      (r'\bphone\b|\bmobile\b', '手机'),
      (r'\bandroid\b', '安卓'),
      (r'\biphone\b', '苹果手机'),
      (r'\bapps?\b|\bgro+z+i+e+\b|\bsuyintong\b', '速印通 APP'),
      (r'\bcompatib(?:le|ility)\b|\bwork(?:s)? with\b', '兼容 支持'),
      (r'\bsupport(?:s|ed|ing)?\b', '支持'),
      (r'\bbluetooth\b', '蓝牙'),
      (r'\bwi-?fi\b', '无线网络'),
      (r'\bpower on\b|\bturn on\b', '开机'),
      (r'\bbattery\b', '电池'),
      (r'\bdate\b|\byear\b', '日期 年份'),
      (r'\btime\b', '时间'),
      (r'\bprint\b|\bprinting\b', '打印'),
      (r'\bpaper\b', '纸张'),
    ]) {
      if (RegExp(pattern).hasMatch(lower)) terms.add(translation);
    }
    return terms.join(' ');
  }
}
