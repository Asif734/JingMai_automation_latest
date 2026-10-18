/// File bytes are reusable; a customer sending those bytes at a different JD
/// message timestamp is a new event. Never use polling/cache modification time.
String mediaMessageStableId(String kind, String digest, DateTime? sentAt) =>
    'visible-$kind:$digest${sentAt == null ? '' : ':${mediaMessageSecond(sentAt)}'}';

int mediaMessageSecond(DateTime sentAt) =>
    sentAt.toUtc().millisecondsSinceEpoch ~/ 1000;

bool sameMediaMessageTime(DateTime? existing, DateTime? incoming) =>
    incoming == null ||
    (existing != null &&
        mediaMessageSecond(existing) == mediaMessageSecond(incoming));
