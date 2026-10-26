/// WebSocket client — mirrors public/js/app.js's WS handling and talks the
/// exact same frame protocol as the backend's websocket/manager.py (frame
/// `type` strings are reused verbatim: 'send', 'typing', 'read', 'message',
/// 'presence', 'receipts', 'ready', 'error', ...).
///
/// Stays connected on its own: when the connection drops (no network, server
/// restart, phone asleep) it keeps retrying with backoff, and emits a
/// synthetic `{'type': 'connected'}` frame each time it's back so screens can
/// re-sync. Chat messages sent while offline go into a persisted outbox and
/// are delivered on reconnect — removed only once the server confirms them
/// ('sent') or rejects them ('error' with the same tempId).
library ws_client;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/io.dart';

class WsClient {
  final Uri uri;

  /// Read fresh on every (re)connect — the server renews the session cookie,
  /// so a value captured once at startup would eventually go stale.
  final Future<String?> Function() cookieProvider;

  /// This phone's device id, so the server hands it its own Signal copies.
  final String? deviceId;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  int _attempt = 0;
  bool _closed = false;
  bool _connecting = false;

  final _incomingController = StreamController<Map<String, dynamic>>.broadcast();

  /// Queued 'send' frames keyed by tempId, oldest first.
  final Map<String, Map<String, dynamic>> _outbox = {};
  bool _outboxLoaded = false;

  /// Every decoded inbound frame — screens/providers filter on `type`.
  Stream<Map<String, dynamic>> get frames => _incomingController.stream;

  bool _connected = false;
  bool get isConnected => _connected;

  WsClient({required this.uri, required this.cookieProvider, this.deviceId});

  /// Starts the connection and keeps it alive until [close].
  Future<void> connect() async {
    _closed = false;
    await _loadOutbox();
    await _open();
  }

  /// Skip the remaining backoff and try right away — e.g. when the app
  /// comes back to the foreground.
  void reconnectNow() {
    if (_closed || _connected || _connecting) return;
    _retryTimer?.cancel();
    _attempt = 0;
    _open();
  }

  Future<void> _open() async {
    if (_closed || _connecting) return;
    _connecting = true;
    try {
      // Same self-signed-cert trust as api_client.dart for wss:// to a LAN server.
      HttpClient? customClient;
      if (uri.scheme == 'wss') {
        customClient = HttpClient()..badCertificateCallback = (cert, host, port) => true;
      }
      final cookie = await cookieProvider();
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: {
          if (cookie != null) 'Cookie': cookie,
          if (deviceId != null) 'x-veyon-device': deviceId!,
        },
        pingInterval: const Duration(seconds: 25),
        connectTimeout: const Duration(seconds: 15),
        customClient: customClient,
      );
      await channel.ready;
      if (_closed) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _connected = true;
      _attempt = 0;
      _sub = channel.stream.listen(
        _onRaw,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: true,
      );
      _flushOutbox();
      _incomingController.add({'type': 'connected'});
    } catch (_) {
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _onRaw(dynamic raw) {
    Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return; // one bad frame shouldn't kill the socket, same as app.js
    }
    final type = frame['type'];
    final tempId = frame['tempId'];
    if ((type == 'sent' || type == 'error') && tempId is String && _outbox.remove(tempId) != null) {
      _saveOutbox();
    }
    _incomingController.add(frame);
  }

  void _onDisconnected() {
    if (_channel == null) return;
    _connected = false;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _incomingController.add({'type': 'disconnected'});
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed) return;
    _retryTimer?.cancel();
    // 1s, 2s, 4s ... capped at 30s, plus jitter so many phones don't all
    // hammer a restarted server at the same instant.
    final seconds = min(30, 1 << min(_attempt, 5));
    _attempt++;
    _retryTimer = Timer(Duration(milliseconds: seconds * 1000 + Random().nextInt(500)), _open);
  }

  void send(Map<String, dynamic> frame) {
    if (!_connected || _channel == null) return;
    // Fields starting with "_" stay on this phone (e.g. the unsealed text of
    // a Signal message, kept so it can be sealed again).
    _channel!.sink.add(jsonEncode({for (final e in frame.entries) if (!e.key.startsWith('_')) e.key: e.value}));
  }

  /// The queued frame for [tempId], if it's still waiting.
  Map<String, dynamic>? outboxFrame(String tempId) => _outbox[tempId];

  /// Replace a queued frame (re-sealed for the current devices) and send it.
  void resend(String tempId, Map<String, dynamic> frame) {
    _outbox[tempId] = frame;
    _saveOutbox();
    send(frame);
  }

  void sendMessage({
    required String conversationId,
    required String ciphertext,
    required String iv,
    String kind = 'text',
    required String tempId,
    String? replyToId,
    String? filePath,
    int? fileSize,
    bool viewOnce = false,
    Map<String, dynamic> extras = const {},
  }) {
    final frame = {
      ...extras,
      'type': 'send',
      'conversationId': conversationId,
      'ciphertext': ciphertext,
      'iv': iv,
      'kind': kind,
      'tempId': tempId,
      if (replyToId != null) 'replyToId': replyToId,
      if (filePath != null) 'filePath': filePath,
      if (fileSize != null) 'fileSize': fileSize,
      if (viewOnce) 'viewOnce': true,
    };
    // Always queue first: if the socket drops between sending and the
    // server's 'sent' confirmation, the message is retried on reconnect
    // instead of being lost.
    _outbox[tempId] = frame;
    _saveOutbox();
    send(frame);
  }

  /// Whether a message is still waiting for the server to confirm it.
  bool isPending(String tempId) => _outbox.containsKey(tempId);

  void sendTyping({required String conversationId, required bool isTyping}) {
    send({'type': 'typing', 'conversationId': conversationId, 'isTyping': isTyping});
  }

  void sendRead({required String conversationId}) {
    send({'type': 'read', 'conversationId': conversationId});
  }

  void _flushOutbox() {
    for (final frame in _outbox.values.toList()) {
      send(frame);
    }
  }

  // ── Outbox persistence (survives the app being closed while offline) ──

  Future<File> _outboxFile() async {
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${dir.path}/veyon_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return File('${cacheDir.path}/outbox.json');
  }

  Future<void> _loadOutbox() async {
    if (_outboxLoaded) return;
    _outboxLoaded = true;
    try {
      final file = await _outboxFile();
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      for (final f in list.cast<Map<String, dynamic>>()) {
        final tempId = f['tempId'];
        if (tempId is String) _outbox[tempId] = f;
      }
    } catch (_) {
      // Corrupt/unreadable outbox — start empty rather than crash.
    }
  }

  Future<void> _saveOutbox() async {
    try {
      final file = await _outboxFile();
      await file.writeAsString(jsonEncode(_outbox.values.toList()));
    } catch (_) {
      // Best-effort; the in-memory queue still retries this session.
    }
  }

  /// Wipes queued messages — only on logout (they belong to that account).
  Future<void> clearOutbox() async {
    _outbox.clear();
    await _saveOutbox();
  }

  Future<void> close() async {
    _closed = true;
    _connected = false;
    _retryTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    close();
    _incomingController.close();
  }
}
