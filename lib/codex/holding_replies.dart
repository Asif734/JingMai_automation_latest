import 'dart:math';

const chineseHoldingReplies = <String>[
  '已收到您的问题，我正在为您仔细核对，请稍候。',
  '感谢您的等待，我正在查询相关信息，会继续为您跟进。',
  '您的问题已收到，我正在确认相关信息，请稍候。',
  '我正在查看您反馈的情况，请稍等一下。',
  '已了解您的需求，我正在核对具体详情。',
  '感谢您的等待，我正在继续核实，请稍候。',
  '我正在整理准确答复，请稍等一下。',
  '您的问题正在进一步确认，我会继续为您处理。',
  '已收到您刚发来的消息，我正在认真核对。',
  '感谢您的耐心，我正在查看具体情况。',
  '我正在为您确认相关信息，请稍等一下。',
  '您的问题已记录，我正在核对详情。',
  '我正在核实您反馈的问题，请稍候。',
  '感谢等待，我正在确认准确答复。',
  '我正在仔细查看您提供的信息，请稍候。',
  '已了解您的情况，我正在核对相关信息。',
  '我会继续处理您的问题，请稍等一下。',
  '您的需求已收到，我正在确认具体详情。',
  '感谢您的等待，我正在为您查询。',
  '我正在核实相关信息，确认后会继续回复您。',
  '已收到您的反馈，我正在查找对应的处理方法。',
  '我正在结合您提供的信息认真排查，请稍候。',
  '感谢您提供这些信息，我正在进一步核对。',
  '您的问题我正在跟进，会尽快给您准确答复。',
  '我正在确认适合您当前情况的处理步骤，请稍候。',
  '已了解您现在的需求，我正在为您核实。',
  '感谢您的配合，我正在继续查看相关资料。',
  '我正在核对产品信息，避免给您不准确的答复。',
  '您的消息已收到，我正在确认下一步处理方法。',
  '我会认真帮您核对这个问题，请稍等一下。',
];

const positiveSupportFallbackReplies = <String>[
  '已收到您的问题，抱歉让您久等了。为了给您准确答复，我正在进一步核对；您提供的信息已保留，无需重复说明。',
  '感谢您提供详细信息。这个问题还需要进一步确认，我会继续为您跟进，您无需重新描述。',
  '非常抱歉本次未能立即给出准确结果。您提供的信息我已完整保留，后续会从当前进度继续核对。',
  '您的问题我已认真记录。为了避免给您错误信息，还需要进一步核实，后续会直接从这里继续处理。',
  '感谢您的耐心配合。目前信息正在进一步核对中，您已提供的内容都会保留，不需要重复发送。',
  '很抱歉让您等待。我们会依据您已经提供的信息继续确认，尽量尽快给您准确的处理结果。',
];

// Keep recognizing holding bubbles sent by earlier releases. Otherwise OCR
// can append one of these seller messages to the customer's next question and
// accidentally feed it back into answer generation.
const _legacyChineseHoldingReplies = <String>[
  '请稍等片刻，我们正在核对您的问题。',
  '感谢您的耐心等待，我们正在为您查询。',
  '请稍候，我们正在确认相关信息。',
  '我们正在查看您的问题，请稍等一下。',
  '请给我们一点时间核对详情。',
  '感谢您的等待，我们还在核实中。',
  '请稍等，我们正在整理答复。',
  '我们正在进一步确认，请您稍候。',
  '请耐心等待片刻，我们正在处理您的问题。',
  '感谢您的耐心，我们正在查看具体情况。',
  '请稍等一下，我们正在为您确认。',
  '我们正在核对详情，请稍候。',
  '请稍等片刻，我们正在核实。',
  '感谢等待，我们正在确认准确答复。',
  '我们正在仔细查看，请您稍候。',
  '请稍候，我们正在核对信息。',
  '我们还在处理您的问题，请稍等。',
  '请给我们一点时间确认详情。',
  '感谢您的等待，我们正在查询。',
  '我们正在核实，很快回复您。',
];

String chooseHoldingReply(String latestCustomerText, {Random? random}) {
  return chineseHoldingReplies[
      (random ?? Random()).nextInt(chineseHoldingReplies.length)];
}

String choosePositiveSupportFallback(String seed) {
  var hash = 0;
  for (final value in seed.runes) {
    hash = (hash * 31 + value) & 0x7fffffff;
  }
  return positiveSupportFallbackReplies[
      hash % positiveSupportFallbackReplies.length];
}

/// Vision may miss the seller label and append our fixed holding bubble to
/// the buyer's text. Preserve explicit quotations of a holding message.
String stripAppendedHoldingReply(String body) {
  if (RegExp('[「」“”"\u0027]').hasMatch(body)) return body;
  var end = body.length;
  for (final holding in [
    ...chineseHoldingReplies,
    ..._legacyChineseHoldingReplies,
    ...positiveSupportFallbackReplies,
    '很抱歉让您久等了。目前资料还不足以确认安全准确的处理方法',
    '请稍等，我正在核对您刚发来的消息。',
    '已收到您刚发来的消息，我正在仔细核对，请稍候。',
  ]) {
    final index = body.indexOf(holding);
    if (index >= 0 && index < end) end = index;
  }
  return body.substring(0, end).trim();
}
