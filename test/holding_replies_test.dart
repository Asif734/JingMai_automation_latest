import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/holding_replies.dart';

void main() {
  test('removes seller holding text appended to a customer question', () {
    expect(stripAppendedHoldingReply('打4联可以的吧请稍等，我正在核对您刚发来的消息。'), '打4联可以的吧');
    expect(
        stripAppendedHoldingReply('是全新的吗请给我们一点时间核对详情。 您好，请问有什么可以帮您？'), '是全新的吗');
    expect(stripAppendedHoldingReply('你说“请给我们一点时间核对详情。”是什么意思？'),
        '你说“请给我们一点时间核对详情。”是什么意思？');
  });
  test('holding replies vary but always use Chinese', () {
    expect(chineseHoldingReplies.toSet(), hasLength(30));
    final random = Random(7);
    for (var index = 0; index < 30; index++) {
      expect(
          chineseHoldingReplies,
          contains(chooseHoldingReply('What are the printer features?',
              random: random)));
      expect(chineseHoldingReplies,
          contains(chooseHoldingReply('这个型号有什么功能？', random: random)));
    }
  });

  test('support fallbacks stay positive and preserve customer effort', () {
    expect(positiveSupportFallbackReplies.toSet(), hasLength(6));
    for (final reply in positiveSupportFallbackReplies) {
      expect(
          reply,
          anyOf(contains('已收到'), contains('感谢'), contains('抱歉'),
              contains('您的问题')));
      expect(reply, anyOf(contains('保留'), contains('继续'), contains('跟进')));
      expect(reply, isNot(contains('无法处理')));
    }
    expect(choosePositiveSupportFallback('same customer'),
        choosePositiveSupportFallback('same customer'));
  });
}
