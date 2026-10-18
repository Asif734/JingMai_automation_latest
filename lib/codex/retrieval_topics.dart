/// Bilingual topic expansion/ranking only. Product answers still come from
/// dataset records; no instructions, specifications, or model facts live here.
const retrievalTopicPatterns = <String, String>{
  'product_availability':
      r'\b(?:do you (?:sell|carry|stock|have)|are you selling|is .{0,35}(?:available|in stock)|(?:stock|availability) of|can i buy)\b|销售|在售|有货|现货|库存|(?:卖|有).{0,25}(?:这款|这个型号|[a-z]{1,5}\d{2,5}[a-z]{0,3}).{0,5}[吗么]|[a-z]{1,5}\d{2,5}[a-z]{0,3}.{0,8}(?:卖|有货)',
  'safety':
      r'\b(?:burn(?:ing|t)?|smok(?:e|ing)|flames?|fire|sparks?|electric shock)\b|着火|起火|冒烟|焦味|烧焦|漏电|电火花|触电',
  'date_setup': r'\bdate\b|\byear\b|日期|年份|年月日|上一年|去年',
  'print_quality':
      r'faint|blurry|blurred|light print|pale print|unclear|missing (?:dots|strokes)|不清晰|模糊|不清楚|字迹.{0,5}浅|打印.{0,5}淡|复写不清|后几联|最后几(?:页|联)|缺针|缺笔|断针|纸厚杆|打印质量',
  'shift_setup':
      r'\bshifts?\b|working (?:time|hours)|班次|上下班|第[一二三123]班|工作时间|[0-9]{1,2}\s*(?:点|[:：][0-9]{2})\s*[-–到至]\s*[0-9]{1,2}',
  'print_speed': r'\bspeeds?\b|\bcps\b|高速|低速|速度|快不快|快一点|更快',
  'paper_feed':
      r'\bstuck(?:ed)?\b|\bjam(?:med|ming)?\b|(?:come|comes|coming) out partway|stop(?:s|ped)? (?:moving|feeding)|卡纸|卡住|走纸|进纸.{0,8}(?:停|不动|异常)|打印.{0,4}一半',
  'paper_loading':
      r'\b(?:re[ -]?)?load(?:ing)?\b[^\n.!?]{0,30}\bpaper\b|\b(?:insert|put|install|set)\b[^\n.!?]{0,30}\bpaper\b|\bpaper roll\b|装纸|重新放纸|纸卷|卷纸',
  'paper_removal':
      r'\b(?:remove|release|take out|pull out)\b[^\n.!?]{0,35}\bpaper\b|取(?:出|下)纸|取出.{0,8}(?:卡|皱).*纸|清除卡纸|排纸|不反向猛拉',
};

Set<String> retrievalTopics(String text) {
  final found = {
    for (final entry in retrievalTopicPatterns.entries)
      if (RegExp(entry.value, caseSensitive: false).hasMatch(text)) entry.key,
  };
  // A safety question supersedes ordinary troubleshooting, even when its
  // supporting sentence also mentions the old jam or printing problem.
  return found.contains('safety') ? {'safety'} : found;
}

String retrievalQuestionText(String query) => query
    .split('\n')
    .where((line) => !RegExp(
            r'^(?:Exact product model|Required product category|Exclude product category|Previous clarification question):',
            caseSensitive: false)
        .hasMatch(line.trim()))
    .join('\n')
    .trim();

/// Keep the latest request plus only the context needed to resolve a short
/// continuation. A model name is carried separately, never as an old symptom.
List<Map<String, dynamic>> focusRetrievalTurns(
    List<Map<String, dynamic>> turns) {
  final meaningful = turns.where((turn) {
    final body = turn['body']?.toString().trim() ?? '';
    return body.isNotEmpty &&
        !RegExp(r'^(?:how are you(?: doing)?|hi|hello|hey|thanks?|thank you|你好|您好|谢谢)[?!.。！？\s]*$',
                caseSensitive: false)
            .hasMatch(body);
  }).toList();
  if (meaningful.isEmpty) return turns.isEmpty ? [] : [turns.last];
  final selected = <Map<String, dynamic>>[meaningful.last];
  var topics = retrievalTopics(meaningful.last['body']?.toString() ?? '');
  for (final previous in meaningful.reversed.skip(1)) {
    final latest = selected.first['body']?.toString() ?? '';
    final earlierTopics = retrievalTopics(previous['body']?.toString() ?? '');
    final reference = RegExp(
                r'^(?:and\b|also\b|then\b|what (?:should|do) i do\b|what about\b|how about\b|yes\b|both\b|again\b|还是|然后|还有|那|就是|对|是的)|\b(?:this|that|it|them)\b',
                caseSensitive: false)
            .hasMatch(latest) ||
        (topics.isEmpty &&
            earlierTopics.isEmpty &&
            !RegExp(r'\?|？|\b(?:what|how|why|when|where)\b|怎么|如何|什么|哪',
                    caseSensitive: false)
                .hasMatch(latest)) ||
        RegExp(r'^(?:android|ios|iphone|bluetooth|wi-?fi|usb|windows|mac(?:os|book)?|安卓|蓝牙|无线|电脑)[.!?。！？\s]*$',
                caseSensitive: false)
            .hasMatch(latest.trim());
    final samePaperSubject = topics.any((t) => t.startsWith('paper_')) &&
        earlierTopics.any((t) => t.startsWith('paper_'));
    if (topics.contains('safety') && !earlierTopics.contains('safety')) break;
    if (!reference &&
        topics.intersection(earlierTopics).isEmpty &&
        !samePaperSubject) {
      break;
    }
    if (topics.isNotEmpty &&
        earlierTopics.isNotEmpty &&
        topics.intersection(earlierTopics).isEmpty &&
        !samePaperSubject) {
      break;
    }
    selected.insert(0, previous);
    topics = {...topics, ...earlierTopics};
    if (selected.length == 3) break;
  }
  return selected;
}

String expandRetrievalTopics(String text) => [
      text
          .replaceAll('针织打印机', '针式打印机')
          .replaceAll(
              RegExp(r'\battendence\b', caseSensitive: false), 'attendance')
          .replaceAll(
              RegExp(r'\bemoloyees?\b', caseSensitive: false), 'employees'),
      for (final topic in retrievalTopics(text))
        switch (topic) {
          'product_availability' =>
            '产品目录 型号 生命周期 Current Legacy Discontinued 在售 历史型号 库存 product catalog model availability',
          'print_quality' => '打印不清晰 复写不清 纸厚杆 色带 faint printing print quality',
          'shift_setup' => '班次设置 上下班时间 考勤机 shift working hours',
          'print_speed' => '打印速度 速度版本 高速 标准 低速 cps mm/s print speed versions',
          'paper_feed' => '卡纸 走纸 进纸 打印一半 纸张检测 paper jam feed stops',
          'paper_loading' => '装纸 纸卷 居中 导纸器 合盖 自动识别 paper roll loading reload',
          'paper_removal' => '取出纸张 关机 卡纸 不反向猛拉 remove jammed paper',
          'safety' => '着火 冒烟 焦味 漏电 电火花 停止使用 安全断电 burning smoke fire safety',
          'date_setup' => '考勤机 日期时间设置 年份 date year time setup',
          _ => '',
        },
    ].join('\n');

String retrievalRecordText(Map<String, Object?> record) => [
      for (final key in const [
        'title',
        'issue',
        'intent',
        'keywords',
        'synonyms',
        'reply_template',
        'content',
        'actions'
      ])
        if (record[key] != null) record[key],
    ].join(' ');

bool hasRequestedTopicEvidence(
    String question, List<Map<String, Object?>> records) {
  final requested = retrievalTopics(question);
  if (requested.isEmpty) return records.length >= 2;
  final supplied =
      records.expand((r) => retrievalTopics(retrievalRecordText(r))).toSet();
  return requested.difference(supplied).isEmpty;
}
