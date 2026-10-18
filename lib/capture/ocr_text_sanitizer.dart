/// Removes JD interface fragments, not product text. Apply only to captured
/// chat text (never to manuals, model names, or text recognized inside media).
String sanitizeJdOcrText(String value) {
  var text = value
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(
          RegExp(
              r'(?:[◎◉○口回□▣]\s*)?(?:按住\s*)?Shift\s*[+＋]\s*Space\s*可\s*快速\s*选中\s*输入框',
              caseSensitive: false),
          '')
      .replaceAll(RegExp(r'(?:风险图片\s*)?当前会话您存在消极服务行为.*?(?:异常反馈|$)'), '')
      .replaceAll(RegExp(r'当前消息可能包含(?:辱骂|[\s，、]).*?(?:异常反馈|$)'), '')
      .replaceAll('你撤回了一条消息', '')
      .replaceAll(RegExp(r'\bC30\b(?:\s*[◎◉○口回□▣])?', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\s+复制\s*$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Vision reads the bubble's Copy/menu/play controls as isolated D/E letters
  // and box glyphs. Do not treat a bare fragment as a customer question.
  const glyphs = '◎◉○口回□▣▢▯▭•·';
  if (isJdOcrControlFragment(text)) return '';
  // Strip a cluster at the edge of a real message, not a single meaningful
  // letter in "press D", "option E", or a model/error code such as M880D/E05.
  final cluster = RegExp(
      '(^|[\\s，。！？；：,.!?;:])(?:[DE](?:\\s+[DE])+(?:\\s*[$glyphs])*|[DE](?:\\s*[$glyphs])+|[$glyphs]+)\\s*\$');
  text =
      text.replaceFirstMapped(cluster, (match) => match.group(1) ?? '').trim();
  final readable = RegExp(r'[A-Za-z0-9\u3400-\u9fff]').allMatches(text).length;
  if (readable <= 1 && RegExp(r'[¿の◎◉○□▣•·]').hasMatch(text)) return '';
  return text;
}

bool isJdOcrControlFragment(String value) {
  if (value.trim() == '复制') return true;
  const glyphs = '◎◉○口回□▣▢▯▭•·';
  return RegExp('^(?:[DE]\\s*|[$glyphs.\\s])+\$').hasMatch(value.trim()) ||
      RegExp('^(?:[gG]\\s*)?[$glyphs.\\s]+\$').hasMatch(value.trim());
}
