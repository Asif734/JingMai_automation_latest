import '../domain/capture_models.dart';

class LocalReplyRouter {
  const LocalReplyRouter();

  static const transferWelcome = '您好，欢迎来到Grozziie客服。请问有什么可以帮您？';

  static const jdOnlyChinese = '本客服账号仅处理京东店铺及京东订单。请问您的京东订单或产品需要什么帮助？';

  static bool isSocialCheckIn(String text) => RegExp(
          r'^(?:(?:hi|hello|hey)[,，!！\s]*)?(?:how are you(?: doing)?(?: today)?|how(?:\x27s| is) it going|你好吗|最近怎么样)[?？!！.。\s]*(?:复制)?$',
          caseSensitive: false)
      .hasMatch(text.trim());

  static const _greetings = <String>{
    'hi',
    'hii',
    'hiii',
    'hello',
    'hellothere',
    'hey',
    'hlw',
    'nihao',
    '你好',
    '您好',
    '在吗',
    '亲在吗',
  };

  static const _thanks = <String>{
    'thanks',
    'thankyou',
    'thankyouverymuch',
    'great',
    'greatthanks',
    'greatthankyou',
    'greatloveyoursupport',
    'appreciateit',
    'awesome',
    'perfect',
    '好的谢谢',
    '谢谢',
    '谢谢你',
    '非常感谢',
    '太好了谢谢',
  };

  AiDraft? route(List<Map<String, dynamic>> messages,
      {DateTime? transferNoticeAt}) {
    Map<String, dynamic>? latestIncoming;
    for (final message in messages.reversed) {
      if (message['direction'] == 'incoming') {
        latestIncoming = message;
        break;
      }
    }
    final body = latestIncoming?['body'];
    if (body is! String) return null;
    final normalized = _normalize(body);
    final isTransfer = _isTransferHandoff(body);
    final isUnsupportedPlatform = _isUnsupportedPlatformQuestion(body);
    final isIdentityQuestion = _isIdentityQuestion(body);
    final isGreeting = _greetings.contains(normalized);
    final isThanks = _thanks.contains(normalized);
    final isSocial = isSocialCheckIn(body);
    if (!isTransfer &&
        !isUnsupportedPlatform &&
        !isIdentityQuestion &&
        !isGreeting &&
        !isThanks &&
        !isSocial) {
      return null;
    }
    // A deterministic greeting is appropriate only for the first customer
    // turn. In an established conversation, Codex must use recent context
    // instead of restarting the interaction.
    final incomingCount =
        messages.where((message) => message['direction'] == 'incoming').length;
    final priorIncoming = messages.reversed
        .skip(1)
        .where((message) => message['direction'] == 'incoming')
        .firstOrNull;
    final latestAt =
        DateTime.tryParse(latestIncoming?['captured_at']?.toString() ?? '');
    final priorAt =
        DateTime.tryParse(priorIncoming?['captured_at']?.toString() ?? '');
    final freshSession = incomingCount == 1 ||
        (latestAt != null &&
            priorAt != null &&
            latestAt.difference(priorAt) >= const Duration(minutes: 30));
    final welcomeAlreadySent = transferNoticeAt != null &&
        messages.any((message) {
          if (message['direction'] != 'outgoing' ||
              message['body'] != transferWelcome) {
            return false;
          }
          final sentAt =
              DateTime.tryParse(message['captured_at']?.toString() ?? '');
          return sentAt != null && !sentAt.isBefore(transferNoticeAt);
        });
    final recentlyTransferred = transferNoticeAt != null &&
        latestAt != null &&
        !latestAt.isBefore(transferNoticeAt) &&
        latestAt.difference(transferNoticeAt) <= const Duration(minutes: 10) &&
        !welcomeAlreadySent;
    // A transfer marker never replaces a real customer request already in the
    // visible history. Let Codex answer that request from recent context.
    if (isTransfer && incomingCount > 1) return null;
    if (!isTransfer && isGreeting && !freshSession && !recentlyTransferred) {
      return null;
    }

    final reply = isSocial
        ? '我很好，感谢您的关心！请问今天有什么可以帮您？'
        : isUnsupportedPlatform
            ? jdOnlyChinese
            : isIdentityQuestion
                ? '我是京东店铺的客服人员，请问有什么可以帮您？'
                : isTransfer
                    ? transferWelcome
                    : isThanks
                        ? '不客气，很高兴能帮到您！'
                        : transferWelcome;
    final response = <String, Object?>{
      'reply': reply,
      'decision': 'draft',
      'confidence': 0.99,
      'used_record_ids': [
        isSocial
            ? 'intent:social_check_in'
            : isUnsupportedPlatform
                ? 'scope:jd_store_only'
                : isIdentityQuestion
                    ? 'identity:customer_service_agent'
                    : isTransfer
                        ? 'intent:transfer_welcome'
                        : isThanks
                            ? 'intent:thanks'
                            : 'intent:greeting'
      ],
      'required_slots': <String>[],
      'actions': <Object?>[],
      'risk_level': 'low',
      'risk_triggers': <String>[],
      'auto_send_allowed': false,
      'model': 'local-intent-router-v1',
      'attachments': <Object?>[],
      'image_descriptions': <Object?>[],
      'human_review_required': false,
      'reason': null,
    };
    return AiDraft.fromJson(response,
        mediaBaseUrl: Uri.parse('http://127.0.0.1'));
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll('0', 'o')
      .replaceAll(RegExp(r'[^a-z\u3400-\u9fff]+'), '');

  bool _isTransferHandoff(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    return RegExp(r'(您的)?同事.+将客户.+转接给您|(?:请你)?转给子账号|上次会话小结.*用户诉求[:：]?.*转接')
        .hasMatch(compact);
  }

  bool _isUnsupportedPlatformQuestion(String value) => RegExp(
        r'微信|微信小程序|微信商城|wechat|weixin|天猫|淘宝|拼多多|抖音|闲鱼|小红书|快手|美团|tmall|taobao|pinduoduo|douyin|xiaohongshu|rednote|kuaishou|meituan|tiktok\s*shop|amazon|ebay|aliexpress',
        caseSensitive: false,
      ).hasMatch(value);

  bool _isIdentityQuestion(String value) => RegExp(
        r'\b(?:are you|you are|r u)\s+(?:an?\s+)?(?:ai|bot|robot|human|real person)|\b(?:ai|chatbot|robot)\b|你是(?:ai|人工智能|机器人|真人)|是真人吗',
        caseSensitive: false,
      ).hasMatch(value);
}
