/// Packaging questions are product facts, not generic conversation. Keep this
/// shared by routing and retrieval so English and Chinese use the same path.
bool hasPackageContentsIntent(String text) => RegExp(
      r'\b(package contents|packaging|box contents|included accessories|complimentary|complementary|free paper|test sheets?)\b'
      r'|\b(?:package|box)\b[^\n.!?]{0,70}\b(?:includes?|included|contents?|papers?|sheets?|cards?|accessories)\b'
      r'|\b(?:includes?|included|contents?|papers?|sheets?|cards?|accessories)\b[^\n.!?]{0,70}\b(?:package|box)\b'
      r'|\b(?:what|how many|how much)[^\n.!?]{0,70}\b(?:comes? with|included|supplied|in the box|are with|is with)\b'
      r'|\b(?:papers?|sheets?|cards?|accessories)[^\n.!?]{0,45}\b(?:included|supplied|comes? with)\b'
      r'|\b(?:included|supplied|comes? with)[^\n.!?]{0,45}\b(?:papers?|sheets?|cards?|accessories)\b'
      r'|包装|装箱|随机配件|随箱|随附|赠纸|赠品|测试纸|(?:送|赠|含|附带).{0,12}(?:多少|几张|纸|卡|配件)|箱子里有什么',
      caseSensitive: false,
    ).hasMatch(text);

/// Only a short referential follow-up inherits the immediately previous topic.
/// An older package question must not reroute a new technical/shipping question.
bool isPackageContentsTurn(String text, String previousCustomerText) {
  if (hasPackageContentsIntent(text)) return true;
  if (!hasPackageContentsIntent(previousCustomerText)) return false;
  final withoutModels = text
      .replaceAll(
          RegExp(r'\b[a-z]{1,5}[ -]?\d{2,5}[a-z]{0,3}\b', caseSensitive: false),
          '')
      .replaceAll(RegExp(r'[\s,.!?，。！？◎]+'), ' ')
      .trim();
  return RegExp(
    r'^(?:also|and|what about|how about|both|the other one|that one|it|还有|那|那么|另一个|这两个|都)?$',
    caseSensitive: false,
  ).hasMatch(withoutModels);
}

bool isPackageContentsRecord(Map<String, Object?> record) => RegExp(
      r'package|packaging|box contents|包装|装箱|随机配件|随箱|随附|测试纸|赠纸',
      caseSensitive: false,
    ).hasMatch([
      record['intent'],
      record['issue'],
      record['title'],
      record['reply_template'],
      record['content'],
    ].whereType<Object>().join(' '));

/// A heading or warning alone is not an answer. Look for actual supplied
/// contents before deciding that the first retrieval pass has sufficient data.
bool hasPackageQuantityIntent(String text) => RegExp(
      r'\b(?:how many|how much|quantity|count)\b|多少|几张|数量',
      caseSensitive: false,
    ).hasMatch(text);

bool packageAnswerStatesMissingFacts(String text) => RegExp(
      r"\b(?:does not|doesn['’]?t|do not|don['’]?t)\s+(?:confirm|specify|state|list|document)\b|\b(?:not|isn['’]?t)\s+(?:confirmed|specified|documented|listed)\b|未确认|未注明|没有说明|无法确认|未明确",
      caseSensitive: false,
    ).hasMatch(text);

bool hasPackageContentsEvidence(Map<String, Object?> record,
        {bool quantityRequired = false}) =>
    isPackageContentsRecord(record) &&
    RegExp(
      r'默认.{0,40}(?:含|纸|卡|线|色带)|(?:标准)?包装.{0,25}(?:内含|包含|含|为)|(?:随机|随箱|随附).{0,30}(?:纸|卡|线|色带)|(?:includes?|supplied|contents)\s*[:：]?.{0,40}(?:paper|sheet|card|cable|ribbon)|(?:Printer|Ribbon Cartridge|USB Cable)',
      caseSensitive: false,
    ).hasMatch([
      record['reply_template'],
      record['content'],
    ].whereType<Object>().join(' ')) &&
    (!quantityRequired ||
        RegExp(r'[0-9零一二两三四五六七八九十百]+\s*(?:张|卷|片|sheets?|papers?|cards?)',
                caseSensitive: false)
            .hasMatch([
          record['reply_template'],
          record['content'],
        ].whereType<Object>().join(' ')));

Set<String> knowledgeProductModels(Object? rawModels) => {
      if (rawModels is List)
        for (final value in rawModels)
          if (RegExp(r'^[a-z]{1,5}\d{2,5}[a-z]{0,3}$', caseSensitive: false)
              .hasMatch(value.toString().replaceAll(RegExp(r'[\s-]'), '')))
            value.toString().toLowerCase().replaceAll(RegExp(r'[\s-]'), ''),
    };

/// Family membership comes from dataset metadata, never from model prefixes.
Set<String> knowledgeProductFamilies(Map<String, Object?> record) {
  // Exported section metadata can inherit the parent document's family even
  // in a mixed-product manual. An explicit leaf heading is more specific:
  // "5. 针式机纸张与速度边界" must not become thermal-printer evidence.
  if (record['status'] != 'active' && record['title'] != null) {
    final heading = record['title'].toString().split('>').last.toLowerCase();
    final headingFamilies = <String>{
      if (RegExp(r'dot.?matrix|needle.?printer|针式').hasMatch(heading))
        'dot_matrix',
      if (RegExp(r'thermal|热敏').hasMatch(heading)) 'thermal',
      if (RegExp(r'attendance|考勤|打卡机').hasMatch(heading)) 'attendance',
    };
    if (headingFamilies.length == 1) return headingFamilies;
  }
  final identity = [
    record['product_line'],
    record['models'],
    record['source_file'],
    record['title'],
  ].whereType<Object>().join(' ').toLowerCase();
  return {
    if (RegExp(r'dot.?matrix|needle.?printer|针式').hasMatch(identity))
      'dot_matrix',
    if (RegExp(r'thermal|热敏').hasMatch(identity)) 'thermal',
    if (RegExp(r'attendance|考勤|打卡机').hasMatch(identity)) 'attendance',
  };
}
