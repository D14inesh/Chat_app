/// Notifications for new messages and incoming calls — the website's
/// notify(): title = the chat's name, body = the message text (or "Sent an
/// attachment", "Sent a voice message", …). Shown while the app is running,
/// unless that chat is already open on screen or muted.
///
/// Note: like the website, this works while the app is open or in the
/// background. Notifications with the app fully closed need a push service
/// (Firebase Cloud Messaging), which this project doesn't have yet.
library message_notifier;

import '../../core/signal/signal_service.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_visibility.dart';
import '../../core/crypto/keys.dart';
import '../../core/key_resolver.dart';
import '../../core/local_notifications.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';

class MessageNotifier {
  final Ref _ref;
  final Session _session;
  StreamSubscription<Map<String, dynamic>>? _sub;

  MessageNotifier(this._ref, this._session) {
    _sub = _session.ws?.frames.listen(_onFrame);
    AppVisibility.openChatId.addListener(_clearOpenChat);
  }

  bool _onScreen(String conversationId) =>
      AppVisibility.inForeground.value && AppVisibility.openChatId.value == conversationId;

  void _clearOpenChat() {
    final id = AppVisibility.openChatId.value;
    if (id != null) LocalNotifications.clearMessage(id);
  }

  Future<void> _onFrame(Map<String, dynamic> frame) async {
    final type = frame['type'];
    final conversationId = frame['conversationId'] as String?;
    if (conversationId == null) return;

    if (type == 'message') {
      if (_session.user?.notifyMessages == false) return; // switched off in Chat features
      final msg = frame['message'] as Map<String, dynamic>?;
      if (msg == null || msg['senderId'] == _session.user?.id) return; // my own, from another device
      if (_onScreen(conversationId)) return;
      final convo = _ref.read(conversationsProvider.notifier).byId(conversationId);
      if (convo == null) return;
      if ((convo.muted || convo.archived) && msg['mentionAll'] != true) return;
      // Locked / private-PIN chats never show who or what.
      if (convo.locked) {
        await LocalNotifications.showMessage(conversationId: conversationId, title: 'Veyon Chat', body: 'New message');
        return;
      }
      final body = await _body(convo, msg);
      final sender = convo.isGroup ? await _senderName(msg['senderId'] as String) : null;
      await LocalNotifications.showMessage(
        conversationId: conversationId,
        // "Manju", or "Manju @ Family" in a group.
        title: sender == null ? convo.displayName('New message') : '$sender @ ${convo.displayName('Group')}',
        body: body,
      );
    } else if (type == 'call-offer' && !AppVisibility.inForeground.value && _session.user?.notifyCalls != false) {
      final convo = _ref.read(conversationsProvider.notifier).byId(conversationId);
      await LocalNotifications.showCall(
        conversationId: conversationId,
        callerName: convo?.displayName('Someone') ?? 'Someone',
        video: frame['callType'] == 'video',
      );
    } else if (type == 'call-end' || type == 'call-decline') {
      await LocalNotifications.clearCall(conversationId);
    }
  }

  Future<String> _body(dynamic convo, Map<String, dynamic> msg) async {
    switch (msg['kind']) {
      case 'voice':
        return '🎤 Voice message';
      case 'location':
        return '📍 Location';
      case 'contact':
        return '👤 Contact';
      case 'poll':
        return '📊 Poll';
      case 'product':
        return '🛍️ Product';
      case 'auto':
        return msg['ciphertext'] as String;
    }
    try {
      final String plain;
      if (msg['ciphertext'] == 'signal') {
        plain = await SignalService.instance.open(
              id: msg['id'] as String,
              senderId: msg['senderId'] as String,
              iv: msg['iv'] as String,
              editedAt: msg['editedAt'] as String?,
              envelope: msg['envelope'] as Map<String, dynamic>?,
            ) ??
            (throw StateError('not on this phone'));
      } else {
        final key = await resolveConversationKey(_session, convo);
        plain = await decryptText(key, msg['ciphertext'] as String, msg['iv'] as String);
      }
      if (msg['kind'] != 'file') return plain;
      // A file's text is its details: say what it is.
      final meta = jsonDecode(plain) as Map<String, dynamic>;
      final mime = meta['mime'] as String? ?? '';
      if (mime.startsWith('image/')) return '📷 Photo';
      if (mime.startsWith('video/')) return '🎥 Video';
      if (mime.startsWith('audio/')) return '🎵 Audio';
      return '📄 ${meta['name'] ?? 'File'}';
    } catch (_) {
      return msg['kind'] == 'file' ? '📎 Attachment' : 'New message';
    }
  }

  Future<String?> _senderName(String userId) async {
    try {
      return (await _session.api.getUser(userId))['displayName'] as String?;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _sub?.cancel();
    AppVisibility.openChatId.removeListener(_clearOpenChat);
  }
}

/// Watched by the signed-in part of the app so it lives as long as the session.
final messageNotifierProvider = Provider<MessageNotifier>((ref) {
  final notifier = MessageNotifier(ref, ref.watch(sessionControllerProvider));
  ref.onDispose(notifier.dispose);
  return notifier;
});
