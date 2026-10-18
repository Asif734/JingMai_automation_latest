import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/capture_models.dart';
import '../domain/customer_identity.dart';
import '../domain/media_identity.dart';
import '../capture/ocr_text_sanitizer.dart';
import '../capture/reply_message_scope.dart';
import '../codex/customer_video_report.dart';

class ConversationFileStore {
  ConversationFileStore(this.rootDirectory);

  final Directory rootDirectory;
  final Map<String, Future<void>> _writeTails = {};

  Directory get conversationsDirectory => rootDirectory;
  Directory get mediaDirectory =>
      Directory(p.join(rootDirectory.path, 'media'));

  Future<CaptureAppendResult> appendCapture(CapturedConversation capture) {
    final userId = capture.customerExternalId ?? capture.customerName;
    // An absent outer verification flag must not permit references to another
    // customer's already-owned media directory or conflicting native proof.
    final ownMediaRoot =
        p.absolute(p.join(mediaDirectory.path, safeUserId(userId)));
    for (final message
        in capture.messages.where((m) => m.direction == 'incoming')) {
      for (final media in message.media) {
        final path = p.normalize(p.absolute(media.path));
        if ((media.verifiedCustomerId != null &&
                media.verifiedCustomerId != userId) ||
            (p.isWithin(p.absolute(mediaDirectory.path), path) &&
                !p.isWithin(ownMediaRoot, path))) {
          throw StateError('Incoming media belongs to a different customer.');
        }
        if (p.isWithin(ownMediaRoot, path)) {
          final file = File(path);
          final owner = Directory(ownMediaRoot);
          _verifyMediaDirectoryOwner(userId, owner);
          if (file.existsSync() &&
              owner.existsSync() &&
              !p.isWithin(owner.resolveSymbolicLinksSync(),
                  file.resolveSymbolicLinksSync())) {
            throw StateError(
                'Incoming media resolves to a different customer.');
          }
        }
      }
    }
    if (capture.verifiedCustomerId case final verified?) {
      if (verified != userId || capture.customerName != userId) {
        throw StateError(
            'Capture customer ID differs from its verified owner.');
      }
      final ownerRoot =
          p.normalize(p.join(mediaDirectory.path, safeUserId(userId)));
      for (final message in capture.messages) {
        if (message.direction == 'incoming' &&
            message.sender != null &&
            !customerSenderLabelMatches(message.sender!, userId)) {
          throw StateError(
              'Incoming sender differs from verified customer $userId.');
        }
        for (final media in message.media) {
          final path = p.normalize(p.absolute(media.path));
          if (!p.isWithin(p.absolute(ownerRoot), path)) {
            throw StateError(
                'Captured media is outside customer $userId storage.');
          }
          final file = File(path);
          final owner = Directory(ownerRoot);
          _verifyMediaDirectoryOwner(userId, owner);
          if (file.existsSync() &&
              owner.existsSync() &&
              !p.isWithin(owner.resolveSymbolicLinksSync(),
                  file.resolveSymbolicLinksSync())) {
            throw StateError(
                'Captured media resolves outside customer $userId storage.');
          }
        }
      }
    }
    return _serialized(userId, () async {
      final document = await _readOrCreate(
        userId: userId,
        displayName: capture.customerName,
        stableKey: capture.stableKey,
      );
      final messages =
          (document['messages'] as List<Object?>).cast<Map<String, Object?>>();
      final knownIds = messages
          .expand((item) => [item['id'], item['original_media_id']])
          .whereType<String>()
          .toSet();
      final knownMediaEvents = <String, List<DateTime?>>{};
      for (final item
          in messages.where((item) => item['direction'] == 'incoming')) {
        final content = _mediaContentKey(item['id']?.toString() ?? '');
        if (content != null) {
          knownMediaEvents
              .putIfAbsent(content, () => [])
              .add(DateTime.tryParse(item['sent_at']?.toString() ?? ''));
        }
      }
      var inserted = 0;
      final insertedIncomingIds = <String>[];
      final insertedOutgoingIds = <String>[];
      String? lastInsertedDirection;
      for (var index = 0; index < capture.messages.length; index++) {
        var message = capture.messages[index];
        if (message.direction == 'incoming' && message.media.isEmpty) {
          final body = sanitizeJdOcrText(message.body);
          if (body.isEmpty) continue;
          if (body != message.body) {
            message = CapturedMessage(
                stableId: message.stableId,
                direction: message.direction,
                body: body,
                sender: message.sender,
                sentAt: message.sentAt,
                axPath: message.axPath,
                deliveryConfirmed: message.deliveryConfirmed);
          }
        }
        if (!knownIds.add(message.stableId)) continue;
        // A verified original upgrades this exact customer's preview event.
        // Preserve the durable ID used by reply cursors; remember the original
        // ID as an alias so subsequent cache scans cannot insert it again.
        final eventKeys = message.media
            .map((m) => m.sourceEventKey)
            .whereType<String>()
            .toSet();
        if (message.direction == 'incoming' &&
            eventKeys.length == 1 &&
            message.media.any((m) => !m.isPartial)) {
          final preview = messages
              .where((item) =>
                  item['direction'] == 'incoming' &&
                  sameMediaMessageTime(
                      DateTime.tryParse(item['sent_at']?.toString() ?? ''),
                      message.sentAt) &&
                  (item['media'] as List<Object?>? ?? const [])
                      .whereType<Map>()
                      .any((m) =>
                          m['source_event_key'] == eventKeys.single &&
                          m['capture_source'] == 'verified_attachment_preview'))
              .firstOrNull;
          if (preview != null) {
            preview
              ..['body'] = message.body
              ..['media'] = [for (final media in message.media) media.toJson()]
              ..['original_media_id'] = message.stableId
              ..['captured_at'] = capture.capturedAt.toUtc().toIso8601String();
            inserted++;
            lastInsertedDirection = 'incoming';
            insertedIncomingIds.add(preview['id']! as String);
            continue;
          }
        }
        final mediaContent = _mediaContentKey(message.stableId);
        if (message.direction == 'incoming' && mediaContent != null) {
          final times = knownMediaEvents.putIfAbsent(mediaContent, () => []);
          if (times.any((time) => sameMediaMessageTime(time, message.sentAt))) {
            continue;
          }
          times.add(message.sentAt);
        }
        // Different media can have identical placeholder text and timestamps.
        // Only the content AND JD send timestamp identify the same media event.
        if (message.direction == 'incoming' && message.media.isEmpty) {
          final canonical = _ocrCanonical(message.body);
          final sameBubbleIndex = messages.lastIndexWhere((item) =>
              item['direction'] == 'incoming' &&
              (item['source'] == 'jd_automation' ||
                  item['source'] == 'qianniu_capture') &&
              _sameIncomingBubbleTime(item['sent_at'], message.sentAt) &&
              _sameBubbleContent(item['body']?.toString() ?? '', message.body));
          if (sameBubbleIndex >= 0) {
            final existing = messages[sameBubbleIndex];
            final existingBody = existing['body']?.toString() ?? '';
            if (_ocrCanonical(message.body).length >
                _ocrCanonical(existingBody).length) {
              existing
                ..['body'] = message.body
                ..['sender'] = message.sender
                ..['sent_at'] = message.sentAt?.toUtc().toIso8601String()
                ..['captured_at'] =
                    capture.capturedAt.toUtc().toIso8601String();
              // The first durable ID is a reply/queue cursor. OCR may refine
              // the body, but replacing that ID orphans the cursor.
              inserted++;
              lastInsertedDirection = 'incoming';
            }
            continue;
          }
          final upgradeIndex = messages.lastIndexWhere((item) {
            if (item['direction'] != 'incoming' ||
                (item['source'] != 'jd_automation' &&
                    item['source'] != 'qianniu_capture')) {
              return false;
            }
            final capturedAt =
                DateTime.tryParse(item['captured_at']?.toString() ?? '');
            if (capturedAt == null ||
                capture.capturedAt.difference(capturedAt).abs() >
                    const Duration(minutes: 2)) {
              return false;
            }
            if (!_sameIncomingBubbleTimestampOrUnknown(
                item['sent_at'], message.sentAt)) {
              return false;
            }
            return _isMoreCompleteVariant(
                item['body']?.toString() ?? '', message.body);
          });
          if (upgradeIndex >= 0) {
            final existing = messages[upgradeIndex];
            final existingCanonical =
                _ocrCanonical(existing['body']?.toString() ?? '');
            if (canonical.length > existingCanonical.length) {
              existing
                ..['body'] = message.body
                ..['sender'] = message.sender
                ..['captured_at'] =
                    capture.capturedAt.toUtc().toIso8601String();
              inserted++;
              lastInsertedDirection = 'incoming';
              final alreadyAnswered = messages.any((item) =>
                  replyAnswersIncoming(
                      reply: item,
                      incomingId: existing['id']?.toString() ?? '',
                      messages: messages));
              if (!alreadyAnswered) {
                insertedIncomingIds
                    .add(existing['id']?.toString() ?? message.stableId);
              }
            }
            continue;
          }
          // Text similarity alone never identifies a JD message. The same
          // question (including changed spacing/punctuation) at a new sender
          // timestamp is new work. Timestamp-scoped checks above/below still
          // suppress OCR variants of the *same* visible bubble.
          final recentDuplicate = messages.reversed.take(12).any((item) {
            if (item['direction'] != 'incoming' ||
                (item['source'] != 'jd_automation' &&
                    item['source'] != 'qianniu_capture')) {
              return false;
            }
            final capturedAt =
                DateTime.tryParse(item['captured_at']?.toString() ?? '');
            if (capturedAt == null ||
                capture.capturedAt.difference(capturedAt).abs() >
                    const Duration(minutes: 2)) {
              return false;
            }
            if (!_sameIncomingBubbleTimestampOrUnknown(
                item['sent_at'], message.sentAt)) {
              return false;
            }
            return _sameOcrWordBag(
                item['body']?.toString() ?? '', message.body);
          });
          if (recentDuplicate) continue;
        }
        if (message.direction == 'outgoing') {
          final matchingAutomatedReply = messages.reversed
              .where((item) =>
                  item['direction'] == 'outgoing' &&
                  (item['source'] == 'generated_reply' ||
                      item['source'] == 'sla_fallback') &&
                  (_sameReply(item['body']?.toString() ?? '', message.body) ||
                      _sameBubbleTime(item['sent_at'], message.sentAt)))
              .firstOrNull;
          if (matchingAutomatedReply != null) {
            // A matching clock alone can be OCR inside a thumbnail. Only the
            // exact reply text with its dated, visible receipt confirms a send.
            if (matchingAutomatedReply['delivery_status'] != 'sent' &&
                message.deliveryConfirmed &&
                message.sentAt != null &&
                _sameReply(matchingAutomatedReply['body']?.toString() ?? '',
                    message.body)) {
              matchingAutomatedReply['delivery_status'] = 'sent';
              matchingAutomatedReply['sent_at'] =
                  message.sentAt!.toUtc().toIso8601String();
              inserted++;
            }
            continue;
          }
        }
        messages.add({
          'id': message.stableId,
          'direction': message.direction,
          'body': message.body,
          'sender': message.sender,
          'sent_at': message.sentAt?.toUtc().toIso8601String(),
          'captured_at': capture.capturedAt.toUtc().toIso8601String(),
          'source': 'jd_automation',
          if (message.deliveryConfirmed) 'delivery_status': 'sent',
          'media': [for (final media in message.media) media.toJson()],
        });
        final unavailable = document['unavailable_customer_media'];
        if (message.direction == 'incoming' &&
            message.media.isNotEmpty &&
            unavailable is Map &&
            message.sentAt != null) {
          final missingAt =
              DateTime.tryParse(unavailable['sent_at']?.toString() ?? '');
          if (missingAt != null &&
              sameMediaMessageTime(message.sentAt, missingAt) &&
              message.media.any((media) =>
                  media.type == unavailable['kind'] && !media.isPartial)) {
            document.remove('unavailable_customer_media');
          }
        }
        inserted++;
        lastInsertedDirection = message.direction;
        if (message.direction == 'incoming') {
          insertedIncomingIds.add(message.stableId);
        } else if (message.direction == 'outgoing') {
          insertedOutgoingIds.add(message.stableId);
        }
      }
      if (inserted > 0) await _write(document, userId);
      return CaptureAppendResult(
        changed: inserted,
        insertedIncomingIds: insertedIncomingIds,
        insertedOutgoingIds: insertedOutgoingIds,
        lastInsertedDirection: lastInsertedDirection,
      );
    });
  }

  /// Adds factual visual descriptions to already captured media without
  /// writing an unsent customer reply into conversation history.
  Future<int> updateMediaDescriptions(
          String userId, Map<String, String> descriptions,
          {Set<String>? messageIds}) =>
      _serialized(userId, () async {
        if (descriptions.isEmpty) return 0;
        final document = await read(userId);
        if (document == null) return 0;
        var changed = 0;
        final messages = document['messages'] as List<Object?>? ?? const [];
        for (final message in messages.whereType<Map<String, dynamic>>()) {
          if (messageIds != null && !messageIds.contains(message['id'])) {
            continue;
          }
          final mediaItems = message['media'] as List<Object?>? ?? const [];
          for (final media in mediaItems.whereType<Map<String, dynamic>>()) {
            final path = media['path']?.toString();
            final description = path == null ? null : descriptions[path];
            if (description == null || media['description'] == description) {
              continue;
            }
            media['description'] = description;
            changed++;
          }
        }
        if (changed > 0) await _write(document, userId);
        return changed;
      });

  Future<bool> saveCustomerVideoReport(
          String userId, CustomerVideoReport report) =>
      _serialized(userId, () async {
        if (report.event.customer != userId) {
          throw StateError('Video report owner mismatch.');
        }
        final document = await read(userId);
        if (document == null) return false;
        final message = (document['messages'] as List)
            .whereType<Map<String, dynamic>>()
            .where((m) =>
                m['id'] == report.event.messageId &&
                m['direction'] == 'incoming')
            .firstOrNull;
        if (message == null ||
            CustomerVideoEvent(userId, message).fingerprint !=
                report.event.fingerprint) {
          return false;
        }
        message['video_report'] = report.toJson();
        for (final media in (message['media'] as List).whereType<Map>()) {
          if (report.descriptions[media['path']] case final description?) {
            media['description'] = description;
          }
        }
        await _write(document, userId);
        return true;
      });

  Future<void> recordVideoReportFailure(
          String userId, List<CustomerVideoEvent> events, String reason) =>
      _serialized(userId, () async {
        if (events.any((e) => e.customer != userId)) {
          throw StateError('Video attempt owner mismatch.');
        }
        final document = await read(userId);
        if (document == null) return;
        var changed = false;
        for (final message in (document['messages'] as List)
            .whereType<Map<String, dynamic>>()) {
          final event =
              events.where((e) => e.messageId == message['id']).firstOrNull;
          if (event == null ||
              message['direction'] != 'incoming' ||
              CustomerVideoEvent(userId, message).fingerprint !=
                  event.fingerprint) {
            continue;
          }
          message['video_report_attempt'] = {
            'status': 'unavailable',
            'analysis_policy_version': customerVideoAnalysisPolicyVersion,
            'user_id': userId,
            'message_id': event.messageId,
            'source_fingerprint': event.fingerprint,
            'reason': reason,
            'attempted_at': DateTime.now().toUtc().toIso8601String(),
          };
          changed = true;
        }
        if (changed) await _write(document, userId);
      });

  Future<bool> hasSimilarImageFingerprint(String userId, String fingerprint,
      {int maximumDistance = 8,
      Set<String>? captureSources,
      DateTime? capturedAfter}) async {
    if (fingerprint.isEmpty) return false;
    final target = BigInt.tryParse(fingerprint, radix: 16);
    if (target == null) return false;
    final document = await read(userId);
    final messages = document?['messages'] as List<Object?>? ?? const [];
    for (final message in messages.whereType<Map<String, dynamic>>()) {
      if (capturedAfter != null) {
        final capturedAt =
            DateTime.tryParse(message['captured_at']?.toString() ?? '');
        if (capturedAt == null || capturedAt.isBefore(capturedAfter)) {
          continue;
        }
      }
      final mediaItems = message['media'] as List<Object?>? ?? const [];
      for (final media in mediaItems.whereType<Map<String, dynamic>>()) {
        if (captureSources != null &&
            !captureSources.contains(media['capture_source']?.toString())) {
          continue;
        }
        final known = BigInt.tryParse(
            media['visual_fingerprint']?.toString() ?? '',
            radix: 16);
        if (known == null) continue;
        var difference = target ^ known;
        var distance = 0;
        while (difference > BigInt.zero && distance <= maximumDistance) {
          difference &= difference - BigInt.one;
          distance++;
        }
        if (distance <= maximumDistance) return true;
      }
    }
    return false;
  }

  // Legacy ID suffixes sometimes used recovery/poll time. Read the actual
  // persisted sent_at field for event identity, not that unreliable suffix.
  String? _mediaContentKey(String id) {
    final match =
        RegExp(r'^(visible-image|visible-video):([^:]+)(?::|$)').firstMatch(id);
    return match == null ? null : '${match.group(1)}:${match.group(2)}';
  }

  Future<bool> hasCapturedMediaContent(
      String userId, String kind, String digest) async {
    final document = await read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return messages.any((message) =>
        message['direction'] == 'incoming' &&
        _mediaContentKey(message['id']?.toString() ?? '') ==
            'visible-$kind:$digest');
  }

  Future<bool> hasCapturedMediaEvent(String userId, String kind, String digest,
      {required DateTime? sentAt}) async {
    final document = await read(userId);
    final messages = (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, dynamic>>();
    return messages.any((message) =>
        message['direction'] == 'incoming' &&
        (_mediaContentKey(
                (message['original_media_id'] ?? message['id'])?.toString() ??
                    '') ==
            'visible-$kind:$digest') &&
        sameMediaMessageTime(
            DateTime.tryParse(message['sent_at']?.toString() ?? ''), sentAt));
  }

  /// Event-scoped preview dedup survives scrolling/restarts. A partial preview
  /// never suppresses a later original; a full original never downgrades to a
  /// preview. Caller keys contain the JD message clock and attachment slot.
  Future<bool> hasAcquiredImageEvent(String userId, String eventKey,
      {String? previewId}) async {
    final document = await read(userId);
    return (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map>()
        .any((message) =>
            message['direction'] == 'incoming' &&
            ((previewId != null && message['id'] == previewId) ||
                (message['media'] as List<Object?>? ?? const [])
                    .whereType<Map>()
                    .any((m) =>
                        m['source_event_key'] == eventKey &&
                        m['type'] == 'image' &&
                        m['is_partial'] != true)));
  }

  /// An original image/video and a later screenshot of its poster are one
  /// event. Exact slot keys protect other same-second attachments. Legacy
  /// videos without keys qualify only for a single visible bubble.
  Future<bool> hasOriginalMediaEvent(
      String userId, DateTime sentAt, String eventKey,
      {bool singleVisibleBubble = false}) async {
    final document = await read(userId);
    return (document?['messages'] as List<Object?>? ?? const [])
        .whereType<Map>()
        .any((m) =>
            m['direction'] == 'incoming' &&
            sameMediaMessageTime(
                DateTime.tryParse(m['sent_at']?.toString() ?? ''), sentAt) &&
            (m['media'] as List<Object?>? ?? const []).whereType<Map>().any(
                (media) =>
                    media['is_partial'] != true &&
                    const ['image', 'video'].contains(media['type']) &&
                    media['capture_source'] != 'jd_video_frame_1fps' &&
                    (media['source_event_key'] == eventKey ||
                        (singleVisibleBubble &&
                            media['type'] == 'video' &&
                            media['source_event_key'] == null))));
  }

  /// Keep a detected-but-unreadable upload distinct from older readable media.
  /// This is capture evidence, not a new reply/transfer or a blocked queue item.
  Future<void> recordMediaCaptureFailure(String userId, String kind,
          {required DateTime? sentAt, required String reason}) =>
      _serialized(userId, () async {
        if (sentAt == null) return; // Poll time must not identify a new upload.
        final document = await _readOrCreate(
            userId: userId, displayName: userId, stableKey: 'customer:$userId');
        final messages =
            (document['messages'] as List<Object?>).whereType<Map>();
        final alreadyReadable = messages.any((message) {
          final at = DateTime.tryParse(message['sent_at']?.toString() ?? '');
          return message['direction'] == 'incoming' &&
              at != null &&
              sameMediaMessageTime(at, sentAt) &&
              (message['media'] as List<Object?>? ?? const [])
                  .whereType<Map>()
                  .any((media) =>
                      media['type'] == kind && media['is_partial'] != true);
        });
        if (alreadyReadable) return;
        final prior = document['unavailable_customer_media'];
        if (prior is Map) {
          final at = DateTime.tryParse(prior['sent_at']?.toString() ?? '');
          if (at != null && at.isAfter(sentAt)) return;
          if (at == sentAt &&
              prior['kind'] == kind &&
              prior['reason'] == reason) {
            return;
          }
        }
        document['unavailable_customer_media'] = {
          'customer_id': userId,
          'event_key': '$kind:${sentAt.toUtc().millisecondsSinceEpoch}',
          'kind': kind,
          'sent_at': sentAt.toUtc().toIso8601String(),
          'reason': reason,
          'status': 'unreadable',
        };
        await _write(document, userId);
      });

  /// Acquisition metadata is not a typed customer message and never advances
  /// reply/SLA cursors. All preview variants update this same upload event.
  Future<void> recordMediaAcquisition(
          String userId, Map<String, Object?> event) =>
      _serialized(userId, () async {
        if (event['customer_id'] != userId) {
          throw StateError('Media event owner mismatch');
        }
        final document = await _readOrCreate(
            userId: userId, displayName: userId, stableKey: userId);
        final events =
            (document['media_acquisition_events'] as List<Object?>? ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, Object?>.from(e))
                .toList();
        final index =
            events.indexWhere((e) => e['event_key'] == event['event_key']);
        if (index >= 0) {
          events[index] = event;
        } else {
          events.add(event);
        }
        document['media_acquisition_events'] =
            events.length <= 64 ? events : events.sublist(events.length - 64);
        await _write(document, userId);
      });

  /// Records the one-time SLA acknowledgement without marking the customer's
  /// request answered. The final generated reply remains independently queued.
  Future<void> appendSlaFallbackSent({
    required String userId,
    required String messageId,
    required String reply,
    String? receiptKey,
  }) =>
      _serialized(userId, () async {
        final document = await _readOrCreate(
          userId: userId,
          displayName: userId,
          stableKey: userId,
        );
        final messages = (document['messages'] as List<Object?>)
            .cast<Map<String, Object?>>();
        if (messages.any((message) =>
            message['source'] == 'sla_fallback' &&
            (message['sla_message_id'] == messageId ||
                (receiptKey != null &&
                    message['media_event_receipt'] == receiptKey)))) {
          return;
        }
        final now = DateTime.now().toUtc();
        messages.add({
          'id':
              'sla:${sha256.convert(utf8.encode('$userId\u001f$messageId\u001f$reply'))}',
          'direction': 'outgoing',
          'body': reply,
          'sender': 'jd-sla-fallback-v1',
          'sent_at': now.toIso8601String(),
          'captured_at': now.toIso8601String(),
          'source': 'sla_fallback',
          'sla_message_id': messageId,
          if (receiptKey != null) 'media_event_receipt': receiptKey,
          'delivery_status': 'sent',
          'media': <Object?>[],
        });
        await _write(document, userId);
      });

  /// Appends a generated reply only after Qianniu confirms the send action.
  /// Unsent drafts intentionally never become conversation history.
  Future<void> appendSentReply({
    required String userId,
    required String displayName,
    required String stableKey,
    required AiDraft draft,
  }) =>
      _serialized(userId, () async {
        final document = await _readOrCreate(
          userId: userId,
          displayName: displayName,
          stableKey: stableKey,
        );
        final now = DateTime.now().toUtc();
        final replyId =
            'assistant:${sha256.convert(utf8.encode('$userId\u001f${now.toIso8601String()}\u001f${draft.reply}'))}';
        (document['messages'] as List<Object?>).add({
          'id': replyId,
          'direction': 'outgoing',
          'body': draft.reply,
          'sender': draft.model,
          'sent_at': now.toIso8601String(),
          'captured_at': now.toIso8601String(),
          'source': 'generated_reply',
          'delivery_status': 'sent',
          'media': [
            for (final attachment in draft.attachments)
              {
                'type': attachment.kind,
                'path': attachment.url.toString(),
                'media_id': attachment.mediaId,
                'caption': attachment.caption,
              }
          ],
          'reply_metadata': {
            'decision': draft.decision,
            'confidence': draft.confidence,
            'risk_level': draft.riskLevel,
            'model': draft.model,
            'used_record_ids': draft.usedRecordIds,
            'actions': draft.actions,
            'raw_response': jsonDecode(draft.rawJson),
          },
        });
        await _write(document, userId);
      });

  /// Removes legacy unsent generated replies written by older builds.
  /// Incoming messages, OCR-observed seller messages, and confirmed generated
  /// sends are preserved.
  Future<int> purgeLegacyUnsentDrafts() =>
      _serialized('*maintenance*', () async {
        if (!await conversationsDirectory.exists()) return 0;
        var removed = 0;
        await for (final entity in conversationsDirectory.list()) {
          if (entity is! File || p.extension(entity.path) != '.json') continue;
          Map<String, Object?> document;
          try {
            document = (jsonDecode(await entity.readAsString())
                    as Map<String, dynamic>)
                .cast<String, Object?>();
          } catch (_) {
            continue;
          }
          final userId = document['user_id']?.toString();
          if (userId != null && userId.isNotEmpty) {
            final customerNamedFile = _conversationFile(userId);
            if (p.absolute(entity.path) != p.absolute(customerNamedFile.path) &&
                !await customerNamedFile.exists()) {
              try {
                await entity.rename(customerNamedFile.path);
              } on FileSystemException {
                // Keep the original file intact if a rename is unavailable.
              }
            }
          }
          final rawMessages = document['messages'];
          if (rawMessages is! List<Object?>) continue;
          final retained = rawMessages.where((item) {
            if (item is! Map<String, dynamic>) return true;
            final unsentDraft = item['source'] == 'generated_reply' &&
                item['delivery_status'] != 'sent';
            if (unsentDraft) removed++;
            return !unsentDraft;
          }).toList(growable: true);
          if (retained.length == rawMessages.length) continue;
          document['messages'] = retained;
          if (userId != null && userId.isNotEmpty) {
            await _write(document, userId);
          }
        }
        return removed;
      });

  Future<bool> confirmObservedOutgoing({
    required String userId,
    required String messageId,
    String deliveryStatus = 'sent',
  }) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return false;
        final message = (document['messages'] as List<Object?>)
            .whereType<Map<String, dynamic>>()
            .where((item) =>
                item['id'] == messageId && item['direction'] == 'outgoing')
            .firstOrNull;
        if (message == null) return false;
        message['delivery_status'] = deliveryStatus;
        await _write(document, userId);
        return true;
      });

  Future<bool> markReplySent({
    required String userId,
    required String reply,
  }) =>
      _serialized(userId, () async {
        final document = await read(userId);
        if (document == null) return false;
        final messages = (document['messages'] as List<Object?>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
        for (final message in messages.reversed) {
          if (message['source'] == 'generated_reply' &&
              message['body'] == reply &&
              message['delivery_status'] != 'sent') {
            final now = DateTime.now().toUtc().toIso8601String();
            message['delivery_status'] = 'sent';
            message['sent_at'] = now;
            await _write(document, userId);
            return true;
          }
        }
        return false;
      });

  Future<List<StoredMessage>> lastMessages(String userId,
      {int limit = 20}) async {
    final document = await read(userId);
    if (document == null) return const [];
    final messages = (document['messages'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .toList(growable: false);
    final selected = messages.length <= limit
        ? messages
        : messages.sublist(messages.length - limit);
    return selected.map((message) {
      final capturedAt =
          DateTime.tryParse(message['captured_at'] as String? ?? '');
      return StoredMessage(
        stableId: message['id'] as String? ?? '',
        direction: message['direction'] as String? ?? 'unknown',
        body: message['body'] as String? ?? '',
        capturedAt:
            capturedAt?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    }).toList(growable: false);
  }

  /// Returns identities backed by real captured conversation evidence.
  /// Fallback-only files are intentionally excluded: older OCR mistakes could
  /// create such files, and using them as aliases would make the mistake
  /// self-perpetuating.
  Future<Set<String>> trustedCustomerIds() async {
    if (!await conversationsDirectory.exists()) return const {};
    final customers = <String>{};
    await for (final entity in conversationsDirectory.list()) {
      if (entity is! File || p.extension(entity.path) != '.json') continue;
      try {
        final document =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final userId = document['user_id']?.toString().trim() ?? '';
        if (!_isCompleteStoredIdentity(userId)) continue;
        final messages = (document['messages'] as List<Object?>? ?? const [])
            .whereType<Map<String, dynamic>>();
        final hasCapturedEvidence = messages.any((message) {
          final source = message['source']?.toString();
          return source == 'jd_automation' ||
              source == 'qianniu_capture' ||
              source == 'generated_reply';
        });
        if (hasCapturedEvidence) customers.add(userId);
      } catch (_) {
        // A malformed or unrelated JSON file cannot become identity evidence.
      }
    }
    return customers;
  }

  Future<Map<String, Object?>?> read(String userId) async {
    _requireIdentity(userId);
    var file = _conversationFile(userId);
    if (!await file.exists()) {
      final legacy = _legacyConversationFile(userId);
      if (!await legacy.exists()) return null;
      _verifyDocumentOwner(
          (jsonDecode(await legacy.readAsString()) as Map<String, dynamic>),
          userId);
      await conversationsDirectory.create(recursive: true);
      try {
        file = await legacy.rename(file.path);
      } on FileSystemException {
        // A concurrent reader may already have migrated it. Otherwise retain
        // read access to the old hashed file without risking data loss.
        if (!await file.exists()) file = legacy;
      }
    }
    final document =
        (jsonDecode(await file.readAsString()) as Map<String, dynamic>)
            .cast<String, Object?>();
    _verifyDocumentOwner(document, userId);
    return document;
  }

  void _requireIdentity(String userId) {
    if (userId.isEmpty ||
        userId == '.' ||
        userId == '..' ||
        userId != userId.trim() ||
        userId.contains('…') ||
        userId.contains('...') ||
        userId == 'Unknown customer') {
      throw StateError('A complete, unchanged customer ID is required.');
    }
  }

  bool _isCompleteStoredIdentity(String userId) =>
      userId.isNotEmpty &&
      userId != '.' &&
      userId != '..' &&
      userId == userId.trim() &&
      !userId.contains('…') &&
      !userId.contains('...') &&
      userId != 'Unknown customer';

  void _verifyDocumentOwner(Map<String, Object?> document, String userId) {
    if (document['user_id'] != userId) {
      throw StateError('Customer history owner mismatch: requested $userId, '
          'stored ${document['user_id']}. No history was merged or overwritten.');
    }
  }

  void _verifyMediaDirectoryOwner(String userId, Directory directory) {
    if (mediaDirectory.existsSync() &&
        directory.existsSync() &&
        directory.resolveSymbolicLinksSync() !=
            p.join(mediaDirectory.resolveSymbolicLinksSync(),
                safeUserId(userId))) {
      throw StateError('Customer media directory points to a different owner.');
    }
  }

  Future<String> saveMedia({
    required String userId,
    required String filename,
    required List<int> bytes,
  }) =>
      _serialized(userId, () async {
        final directory =
            Directory(p.join(mediaDirectory.path, safeUserId(userId)));
        await directory.create(recursive: true);
        _verifyMediaDirectoryOwner(userId, directory);
        final extension = p.extension(filename).toLowerCase();
        final safeExtension = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
            ? extension
            : '.bin';
        final digest = sha256.convert(bytes).toString();
        final path = p.join(directory.path, '$digest$safeExtension');
        final file = File(path);
        if (await file.exists()) {
          if (!p.isWithin(directory.resolveSymbolicLinksSync(),
                  file.resolveSymbolicLinksSync()) ||
              (await sha256.bind(file.openRead()).first).toString() != digest) {
            throw StateError(
                'Existing media file is not owned matching content.');
          }
        } else {
          await file.writeAsBytes(bytes, flush: true);
        }
        return path;
      });

  String safeUserId(String userId) {
    final trimmed = userId.trim();
    if (trimmed.isEmpty) {
      return 'user_${sha256.convert(utf8.encode(userId))}';
    }
    var safe = trimmed.replaceAll(RegExp(r'[/\\:\x00-\x1f\x7f]'), '_');
    final changed = safe != trimmed;
    if (utf8.encode(safe).length > 180) {
      safe = String.fromCharCodes(safe.runes.take(48));
    }
    if (changed || safe != trimmed) {
      final suffix =
          sha256.convert(utf8.encode(trimmed)).toString().substring(0, 10);
      safe = '${safe}_$suffix';
    }
    return safe;
  }

  String _legacySafeUserId(String userId) {
    final trimmed = userId.trim();
    if (RegExp(r'^[A-Za-z0-9._-]{1,100}$').hasMatch(trimmed)) return trimmed;
    return 'user_${sha256.convert(utf8.encode(trimmed))}';
  }

  String _ocrCanonical(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'''[.,!?;:'"`~，。！？；：“”‘’（）()\[\]{}、]'''), '');

  bool _sameOcrWordBag(String left, String right) {
    List<String> tokens(String value) => RegExp(r'[a-z0-9]+|[\u3400-\u9fff]')
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .toList()
      ..sort();

    final leftTokens = tokens(left);
    final rightTokens = tokens(right);
    if (leftTokens.length < 3 || leftTokens.length != rightTokens.length) {
      return false;
    }
    for (var index = 0; index < leftTokens.length; index++) {
      if (leftTokens[index] != rightTokens[index]) return false;
    }
    return true;
  }

  bool _isMoreCompleteVariant(String existing, String observed) {
    final left = _ocrCanonical(existing);
    final right = _ocrCanonical(observed);
    if (left.isEmpty || right.isEmpty || left == right) return false;
    final shorter = left.length < right.length ? left : right;
    final longer = left.length < right.length ? right : left;
    if (shorter.length >= 8 && longer.contains(shorter)) return true;

    Set<String> words(String value) => RegExp(r'[a-z0-9]+|[\u3400-\u9fff]')
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .toSet();
    final leftWords = words(existing);
    final rightWords = words(observed);
    final smaller =
        leftWords.length < rightWords.length ? leftWords : rightWords;
    final larger =
        leftWords.length < rightWords.length ? rightWords : leftWords;
    return smaller.length >= 3 &&
        larger.length > smaller.length &&
        larger.containsAll(smaller);
  }

  bool _sameReply(String generated, String observed) {
    final left = _ocrCanonical(generated);
    final right = _ocrCanonical(observed);
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    final shorter = left.length < right.length ? left : right;
    final longer = left.length < right.length ? right : left;
    if (shorter.length >= 15 && longer.contains(shorter)) return true;

    Set<String> words(String value) => RegExp(r'[a-z0-9]+|[\u3400-\u9fff]')
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .toSet();
    final generatedWords = words(generated);
    final observedWords = words(observed);
    final smallerWords = generatedWords.length < observedWords.length
        ? generatedWords
        : observedWords;
    if (smallerWords.length < 6) return false;
    final overlap = generatedWords.intersection(observedWords).length;
    return overlap >= 6 && overlap / smallerWords.length >= 0.75;
  }

  bool _sameBubbleTime(Object? storedValue, DateTime? observed) {
    if (observed == null) return false;
    final stored = DateTime.tryParse(storedValue?.toString() ?? '');
    if (stored == null) return false;
    return stored.toUtc().difference(observed.toUtc()).abs() <=
        const Duration(seconds: 3);
  }

  /// A close timestamp alone does not identify a chat bubble: customers often
  /// send several separate messages within three seconds. Only coalesce close
  /// observations when OCR is re-reading the same text or a partial/expanded
  /// version of that text.
  bool _sameBubbleContent(String stored, String observed) {
    final left = _ocrCanonical(stored);
    final right = _ocrCanonical(observed);
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    final shorter = left.length < right.length ? left : right;
    final longer = left.length < right.length ? right : left;
    if (shorter.length >= 3 && longer.contains(shorter)) return true;
    // This check is only used when JD reports the exact same bubble clock.
    // Treat a small OCR spelling correction as another reading of that bubble
    // (for example "please transter" -> "please transfer"), not as a new
    // customer turn that can start another SLA fallback window.
    if (shorter.length >= 6) {
      final maximumEdits = longer.length >= 14 ? 2 : 1;
      if (_editDistanceAtMost(left, right, maximumEdits)) return true;
    }

    Set<String> tokens(String value) => RegExp(r'[a-z0-9]+|[\u3400-\u9fff]')
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .toSet();
    final leftTokens = tokens(stored);
    final rightTokens = tokens(observed);
    final smallerTokens =
        leftTokens.length < rightTokens.length ? leftTokens : rightTokens;
    if (smallerTokens.length < 2) return false;
    final overlap = leftTokens.intersection(rightTokens).length;
    return overlap >= 2 && overlap / smallerTokens.length >= 0.66;
  }

  bool _editDistanceAtMost(String left, String right, int limit) {
    if ((left.length - right.length).abs() > limit) return false;
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var leftIndex = 1; leftIndex <= left.length; leftIndex++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = leftIndex;
      for (var rightIndex = 1; rightIndex <= right.length; rightIndex++) {
        final substitutionCost =
            left.codeUnitAt(leftIndex - 1) == right.codeUnitAt(rightIndex - 1)
                ? 0
                : 1;
        current[rightIndex] = [
          current[rightIndex - 1] + 1,
          previous[rightIndex] + 1,
          previous[rightIndex - 1] + substitutionCost,
        ].reduce((a, b) => a < b ? a : b);
      }
      previous = current;
    }
    return previous.last <= limit;
  }

  bool _sameIncomingBubbleTime(Object? storedValue, DateTime? observed) {
    if (observed == null) return false;
    final stored = DateTime.tryParse(storedValue?.toString() ?? '');
    if (stored == null) return false;
    // JD timestamps identify the bubble to the second. Nearby timestamps are
    // commonly separate rapid messages and must remain separate.
    return stored.toUtc().millisecondsSinceEpoch ==
        observed.toUtc().millisecondsSinceEpoch;
  }

  bool _sameIncomingBubbleTimestampOrUnknown(
      Object? storedValue, DateTime? observed) {
    if (observed == null) {
      return DateTime.tryParse(storedValue?.toString() ?? '') == null;
    }
    return _sameIncomingBubbleTime(storedValue, observed);
  }

  Future<Map<String, Object?>> _readOrCreate({
    required String userId,
    required String displayName,
    required String stableKey,
  }) async {
    final existing = await read(userId);
    if (existing != null) {
      existing['display_name'] = displayName;
      existing['stable_key'] = stableKey;
      return existing;
    }
    return {
      'schema_version': 1,
      'user_id': userId,
      'display_name': displayName,
      'stable_key': stableKey,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'messages': <Object?>[],
    };
  }

  Future<void> _write(Map<String, Object?> document, String userId) async {
    _requireIdentity(userId);
    _verifyDocumentOwner(document, userId);
    // Check any existing file before replacement, including case/Unicode
    // collisions on the normal case-insensitive macOS filesystem.
    await read(userId);
    await conversationsDirectory.create(recursive: true);
    document['updated_at'] = DateTime.now().toUtc().toIso8601String();
    final destination = _conversationFile(userId);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document),
      flush: true,
    );
    await temporary.rename(destination.path);
  }

  File _conversationFile(String userId) =>
      File(p.join(conversationsDirectory.path, '${safeUserId(userId)}.json'));

  File _legacyConversationFile(String userId) => File(
      p.join(conversationsDirectory.path, '${_legacySafeUserId(userId)}.json'));

  Future<T> _serialized<T>(String userId, Future<T> Function() action) {
    _requireIdentity(userId);
    final pathKey = safeUserId(userId).toLowerCase();
    final completer = Completer<T>();
    final previous = _writeTails[pathKey] ?? Future<void>.value();
    _writeTails[pathKey] = previous.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}

class CaptureAppendResult {
  const CaptureAppendResult({
    required this.changed,
    required this.insertedIncomingIds,
    required this.insertedOutgoingIds,
    required this.lastInsertedDirection,
  });

  final int changed;
  final List<String> insertedIncomingIds;
  final List<String> insertedOutgoingIds;
  final String? lastInsertedDirection;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
