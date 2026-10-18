import 'dart:convert';

enum CaptureStatus {
  stopped,
  waitingForPermission,
  waitingForQianniu,
  running,
  error
}

class CapturedConversation {
  const CapturedConversation({
    required this.stableKey,
    required this.customerName,
    this.customerExternalId,
    this.verifiedCustomerId,
    required this.messages,
    required this.capturedAt,
  });

  factory CapturedConversation.fromMap(Map<Object?, Object?> map) {
    final rawMessages = (map['messages'] as List<Object?>? ?? const []);
    return CapturedConversation(
      stableKey: map['stableKey']! as String,
      customerName: (map['customerName'] as String?) ?? 'Unknown customer',
      customerExternalId: map['customerExternalId'] as String?,
      verifiedCustomerId: map['verifiedCustomerId'] as String?,
      messages: rawMessages
          .cast<Map<Object?, Object?>>()
          .map(CapturedMessage.fromMap)
          .toList(growable: false),
      capturedAt:
          DateTime.fromMillisecondsSinceEpoch(map['capturedAtMs']! as int),
    );
  }

  final String stableKey;
  final String customerName;
  final String? customerExternalId;
  final String? verifiedCustomerId;
  final List<CapturedMessage> messages;
  final DateTime capturedAt;
}

class CapturedMessage {
  const CapturedMessage({
    required this.stableId,
    required this.direction,
    required this.body,
    this.sender,
    this.sentAt,
    required this.axPath,
    this.media = const [],
    this.deliveryConfirmed = false,
  });

  factory CapturedMessage.fromMap(Map<Object?, Object?> map) => CapturedMessage(
        stableId: map['stableId']! as String,
        direction: map['direction']! as String,
        body: map['body']! as String,
        sender: map['sender'] as String?,
        sentAt: map['sentAtMs'] is int
            ? DateTime.fromMillisecondsSinceEpoch(map['sentAtMs']! as int)
            : null,
        axPath: (map['axPath'] as String?) ?? '',
        deliveryConfirmed: map['deliveryConfirmed'] == true,
        media: (map['media'] as List<Object?>? ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map(CapturedMedia.fromMap)
            .toList(growable: false),
      );

  final String stableId;
  final String direction;
  final String body;
  final String? sender;
  final DateTime? sentAt;
  final String axPath;
  final List<CapturedMedia> media;

  /// Positive receipt observed next to this exact outgoing bubble. This is
  /// required before OCR can settle reply bookkeeping or recover an uncertain
  /// send. It never gates generation or an ordinary Send attempt.
  final bool deliveryConfirmed;
}

class CapturedMedia {
  const CapturedMedia({
    required this.type,
    required this.path,
    this.mimeType,
    this.originalName,
    this.captureSource,
    this.sourceEventKey,
    this.isPartial = false,
    this.description,
    this.visualFingerprint,
    this.contentSha256,
    this.verifiedCustomerId,
    this.ownershipVerification,
    this.speechTranscript,
    this.speechLanguage,
    this.speechConfidence,
  });

  factory CapturedMedia.fromMap(Map<Object?, Object?> map) => CapturedMedia(
        type: map['type'] as String? ?? 'file',
        path: map['path'] as String? ?? '',
        mimeType: map['mimeType'] as String?,
        originalName: map['originalName'] as String?,
        captureSource:
            (map['captureSource'] ?? map['capture_source']) as String?,
        sourceEventKey:
            (map['sourceEventKey'] ?? map['source_event_key']) as String?,
        isPartial: (map['isPartial'] ?? map['is_partial']) == true,
        description: map['description'] as String?,
        visualFingerprint:
            (map['visualFingerprint'] ?? map['visual_fingerprint']) as String?,
        contentSha256:
            (map['contentSha256'] ?? map['content_sha256']) as String?,
        verifiedCustomerId: (map['verifiedCustomerId'] ??
            map['verified_customer_id']) as String?,
        ownershipVerification: (map['ownershipVerification'] ??
            map['ownership_verification']) as String?,
        speechTranscript: map['speech_transcript'] as String?,
        speechLanguage: map['speech_language'] as String?,
        speechConfidence: (map['speech_confidence'] as num?)?.toDouble(),
      );

  final String type;
  final String path;
  final String? mimeType;
  final String? originalName;
  final String? captureSource;
  final String? sourceEventKey;
  final bool isPartial;
  final String? description;
  final String? visualFingerprint;
  final String? contentSha256;
  final String? verifiedCustomerId;
  final String? ownershipVerification;
  final String? speechTranscript;
  final String? speechLanguage;
  final double? speechConfidence;

  Map<String, Object?> toJson() => {
        'type': type,
        'path': path,
        'mime_type': mimeType,
        'original_name': originalName,
        'capture_source': captureSource,
        if (sourceEventKey != null) 'source_event_key': sourceEventKey,
        'is_partial': isPartial,
        'description': description,
        'visual_fingerprint': visualFingerprint,
        if (contentSha256 != null) 'content_sha256': contentSha256,
        if (verifiedCustomerId != null)
          'verified_customer_id': verifiedCustomerId,
        if (ownershipVerification != null)
          'ownership_verification': ownershipVerification,
        if (speechTranscript != null) 'speech_transcript': speechTranscript,
        if (speechLanguage != null) 'speech_language': speechLanguage,
        if (speechConfidence != null) 'speech_confidence': speechConfidence,
      };
}

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.userId,
    required this.customerName,
    required this.stableKey,
    required this.lastActivityAt,
    required this.messages,
  });

  final int id;
  final String userId;
  final String customerName;
  final String stableKey;
  final DateTime lastActivityAt;
  final List<StoredMessage> messages;
}

class StoredMessage {
  const StoredMessage({
    required this.stableId,
    required this.direction,
    required this.body,
    required this.capturedAt,
  });

  final String stableId;
  final String direction;
  final String body;
  final DateTime capturedAt;
}

class BackendHealth {
  const BackendHealth({
    required this.available,
    required this.openAiConfigured,
    required this.indexReady,
    required this.records,
    required this.model,
  });

  final bool available;
  final bool openAiConfigured;
  final bool indexReady;
  final int records;
  final String model;
}

class HumanReviewTicket {
  const HumanReviewTicket({
    required this.id,
    required this.conversationId,
    required this.customerRequest,
    required this.reason,
    required this.status,
    this.assignedTo,
  });

  factory HumanReviewTicket.fromJson(Map<String, Object?> json) =>
      HumanReviewTicket(
        id: (json['id'] as num).toInt(),
        conversationId: json['conversation_id']! as String,
        customerRequest: json['customer_request']! as String,
        reason: json['reason']! as String,
        status: json['status']! as String,
        assignedTo: json['assigned_to'] as String?,
      );

  final int id;
  final String conversationId;
  final String customerRequest;
  final String reason;
  final String status;
  final String? assignedTo;
}

class TransferAccountPreview {
  const TransferAccountPreview({
    required this.sourceAccount,
    required this.activeAccounts,
  });

  final String sourceAccount;
  final List<String> activeAccounts;
}

class ChatTransferLog {
  const ChatTransferLog({
    required this.id,
    required this.ticketId,
    required this.conversationId,
    required this.sourceAccount,
    required this.reason,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.targetAccount,
    this.error,
  });

  factory ChatTransferLog.fromJson(Map<String, Object?> json) =>
      ChatTransferLog(
        id: (json['id'] as num).toInt(),
        ticketId: (json['ticket_id'] as num).toInt(),
        conversationId: json['user_id']! as String,
        sourceAccount: json['source_account']! as String,
        targetAccount: json['target_account'] as String?,
        reason: json['reason']! as String,
        status: json['status']! as String,
        error: json['error'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (json['created_at_ms'] as num).toInt()),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (json['updated_at_ms'] as num).toInt()),
      );

  final int id;
  final int ticketId;
  final String conversationId;
  final String sourceAccount;
  final String? targetAccount;
  final String reason;
  final String status;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class DraftAttachment {
  const DraftAttachment({
    required this.mediaId,
    required this.kind,
    required this.caption,
    required this.url,
  });

  final String mediaId;
  final String kind;
  final String caption;
  final Uri url;
}

class AiDraft {
  const AiDraft({
    required this.reply,
    required this.decision,
    required this.confidence,
    required this.riskLevel,
    required this.model,
    required this.usedRecordIds,
    required this.actions,
    required this.attachments,
    required this.rawJson,
    this.imageDescriptions = const {},
    this.ticket,
  });

  factory AiDraft.fromJson(Map<String, Object?> json,
      {required Uri mediaBaseUrl}) {
    final rawAttachments = json['attachments'] as List<Object?>? ?? const [];
    return AiDraft(
      reply: json['reply'] as String? ?? '',
      decision: json['decision'] as String? ?? 'human_review_required',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      riskLevel: json['risk_level'] as String? ?? 'unknown',
      model: json['model'] as String? ?? 'unknown',
      usedRecordIds: (json['used_record_ids'] as List<Object?>? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      actions: (json['actions'] as List<Object?>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((value) => value['description']?.toString() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      attachments:
          rawAttachments.whereType<Map<String, dynamic>>().map((value) {
        final mediaId = value['media_id']?.toString() ?? '';
        final localPath = value['path']?.toString();
        return DraftAttachment(
          mediaId: mediaId,
          kind: value['kind']?.toString() ?? 'image',
          caption: value['caption']?.toString() ?? '',
          url: localPath == null || localPath.isEmpty
              ? mediaBaseUrl.resolve('/v1/media/$mediaId')
              : Uri.file(localPath),
        );
      }).toList(growable: false),
      rawJson: jsonEncode(json),
      imageDescriptions: {
        for (final item
            in (json['image_descriptions'] as List<Object?>? ?? const []))
          if (item is Map<String, dynamic> &&
              (item['path']?.toString() ?? '').isNotEmpty &&
              (item['description']?.toString() ?? '').isNotEmpty)
            item['path'].toString(): item['description'].toString(),
      },
      ticket: json['ticket'] is Map<String, dynamic>
          ? HumanReviewTicket.fromJson(
              (json['ticket'] as Map<String, dynamic>).cast<String, Object?>())
          : null,
    );
  }

  final String reply;
  final String decision;
  final double confidence;
  final String riskLevel;
  final String model;
  final List<String> usedRecordIds;
  final List<String> actions;
  final List<DraftAttachment> attachments;
  final String rawJson;
  final Map<String, String> imageDescriptions;
  final HumanReviewTicket? ticket;
}

class StoredDraft {
  const StoredDraft({
    required this.id,
    required this.conversationId,
    required this.draft,
    required this.createdAt,
  });

  final int id;
  final int conversationId;
  final AiDraft draft;
  final DateTime createdAt;
}
