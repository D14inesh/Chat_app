/// REST client — mirrors public/js/app.js's `api()` helper: same cookie-
/// session auth (no bearer tokens, no API changes needed), same error-shape
/// expectation (`{"error": "..."}`, which main.py's exception handler
/// already guarantees for every route — see server-py/main.py).
library api_client;

import 'dart:io';
import 'dart:math';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  final Dio _dio;
  final PersistCookieJar cookieJar;
  final String baseUrl;

  ApiClient._(this._dio, this.cookieJar, this.baseUrl, this.deviceId);

  /// This phone's id (one account per device; also its Signal device).
  final String deviceId;

  /// [baseUrl] should be e.g. `http://10.0.2.2:4000` for the Android
  /// emulator (which maps that address to the host machine's localhost) or
  /// `http://<lan-ip>:4000` for a physical device on the same network —
  /// `localhost` from the device/emulator itself would mean the device, not
  /// the machine running server-py.
  static Future<ApiClient> create(String baseUrl) async {
    final dir = await getApplicationDocumentsDirectory();
    final cookieJar = PersistCookieJar(storage: FileStorage('${dir.path}/.cookies/'));
    final deviceId = await _deviceId(dir.path);
    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (_) => true, // handle non-2xx ourselves, see _unwrap
      headers: {
        // Names this device in "new login" alerts and the login history.
        'x-veyon-client': 'Veyon app on ${Platform.isIOS ? 'iPhone' : 'Android'}',
        // One account per device: the server locks this phone to the
        // first account that signs in on it.
        'x-veyon-device': deviceId,
      },
    ));
    dio.interceptors.add(CookieManager(cookieJar));

    // The rack server's HTTPS listener uses the same self-signed cert the
    // web app already asks browsers to "proceed anyway" through for LAN
    // access (see server-py/main.py + certs/). A mobile HTTP client refuses
    // an untrusted cert by default with no click-through option, so this
    // explicitly trusts it — acceptable while it's a self-signed dev cert
    // pinned to a server you control; revisit once that's a real CA cert.
    if (baseUrl.startsWith('https')) {
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        final client = HttpClient();
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      };
    }

    return ApiClient._(dio, cookieJar, baseUrl, deviceId);
  }

  /// The phone's Android ID (kept across app reinstalls), falling back to
  /// an id saved in the app's files if the platform won't give one.
  static Future<String> _deviceId(String docsDir) async {
    try {
      final id = await const MethodChannel('veyon/call').invokeMethod<String>('deviceId');
      if (id != null && RegExp(r'^[A-Za-z0-9]{8,64}$').hasMatch(id)) return 'android:$id';
    } catch (_) {/* not Android, or no channel — use the saved id */}
    final file = File('$docsDir/.device_id');
    try {
      final saved = (await file.readAsString()).trim();
      if (saved.isNotEmpty) return saved;
    } catch (_) {}
    final rnd = Random.secure();
    final id = 'app:${List.generate(24, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    await file.writeAsString(id);
    return id;
  }

  T _unwrap<T>(Response response, T Function(dynamic data) onOk) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) {
      return onOk(response.data);
    }
    final data = response.data;
    final message = (data is Map && data['error'] is String)
        ? data['error'] as String
        : 'Request failed ($status)';
    throw ApiException(status, message);
  }

  // ── Auth ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> register({
    required String username,
    required String displayName,
    required String password,
    required Map<String, dynamic> publicKey,
    required Map<String, dynamic> encPrivateKey,
    required String phone,
    required String email,
    required String otp,
    String? birthDate,
  }) async {
    final res = await _dio.post('/api/auth/register', data: {
      if (birthDate != null) 'birthDate': birthDate,
      'username': username,
      'displayName': displayName,
      'password': password,
      'publicKey': publicKey,
      'encPrivateKey': encPrivateKey,
      'phone': phone,
      'email': email,
      'otp': otp,
    });
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> login({required String username, required String password}) async {
    final res = await _dio.post('/api/auth/login', data: {'username': username, 'password': password});
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  Future<void> logout() async {
    final res = await _dio.post('/api/auth/logout');
    _unwrap(res, (_) => null);
  }

  /// Emails a 6-digit code to [email]. `signup` for a new account, else
  /// for adding/changing my own number + Gmail. Returns {sent, devCode?}.
  Future<Map<String, dynamic>> sendContactCode({required String phone, required String email, bool signup = false}) async {
    final res = await _dio.post(signup ? '/api/auth/otp' : '/api/auth/contact/otp', data: {'phone': phone, 'email': email});
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  /// Saves my verified number + Gmail. Returns {phone, email, contactVerified}.
  Future<Map<String, dynamic>> saveContact({required String phone, required String email, required String otp}) async {
    final res = await _dio.post('/api/auth/contact', data: {'phone': phone, 'email': email, 'otp': otp});
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  // ── Generic JSON calls (newer features use these instead of one method
  // per endpoint). A null/empty body comes back as {}. ──

  Map<String, dynamic> _asMap(dynamic d) => d is Map<String, dynamic> ? d : <String, dynamic>{};

  Future<Map<String, dynamic>> getJson(String path, {Map<String, dynamic>? query}) async =>
      _unwrap(await _dio.get(path, queryParameters: query), _asMap);

  Future<Map<String, dynamic>> postJson(String path, [Object? data]) async =>
      _unwrap(await _dio.post(path, data: data ?? const <String, dynamic>{}), _asMap);

  Future<Map<String, dynamic>> patchJson(String path, [Object? data]) async =>
      _unwrap(await _dio.patch(path, data: data ?? const <String, dynamic>{}), _asMap);

  Future<Map<String, dynamic>> putJson(String path, [Object? data]) async =>
      _unwrap(await _dio.put(path, data: data ?? const <String, dynamic>{}), _asMap);

  Future<Map<String, dynamic>> deleteJson(String path) async => _unwrap(await _dio.delete(path), _asMap);

  /// A form with an optional photo (product catalogue).
  Future<Map<String, dynamic>> sendForm(String method, String path, Map<String, String> fields,
      {List<int>? photo, String photoMime = 'image/jpeg'}) async {
    final ext = photoMime.split('/').last == 'jpeg' ? 'jpg' : photoMime.split('/').last;
    final form = FormData.fromMap({
      ...fields,
      if (photo != null) 'photo': MultipartFile.fromBytes(photo, filename: 'photo.$ext', contentType: DioMediaType.parse(photoMime)),
    });
    return _unwrap(await _dio.request(path, data: form, options: Options(method: method)), _asMap);
  }

  Future<Map<String, dynamic>> deleteJsonWithBody(String path, Object data) async =>
      _unwrap(await _dio.delete(path, data: data), _asMap);

  /// Frees this phone from my account and signs it out (one account per device).
  Future<void> releaseDevice() async {
    final res = await _dio.post('/api/auth/device/release');
    _unwrap(res, (_) => null);
  }

  /// Raw bytes of a file (images) — goes through this client so the server's
  /// self-signed certificate is accepted.
  Future<Uint8List> getBytes(String path) async {
    final res = await _dio.get<List<int>>(path, options: Options(responseType: ResponseType.bytes));
    if ((res.statusCode ?? 500) >= 400 || res.data == null) throw Exception('Could not load $path');
    return Uint8List.fromList(res.data!);
  }

  Future<Map<String, dynamic>> me() async {
    final res = await _dio.get('/api/auth/me');
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  // ── Conversations ───────────────────────────────────────────────────

  Future<List<dynamic>> listConversations() async {
    final res = await _dio.get('/api/conversations');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['conversations'] as List<dynamic>);
  }

  Future<Map<String, dynamic>> openDirectConversation(String peerUserId) async {
    final res = await _dio.post('/api/conversations/direct', data: {'userId': peerUserId});
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['conversation'] as Map<String, dynamic>);
  }

  Future<void> acceptRequest(String conversationId) async {
    final res = await _dio.post('/api/conversations/$conversationId/accept');
    _unwrap(res, (_) => null);
  }

  Future<void> declineRequest(String conversationId) async {
    final res = await _dio.post('/api/conversations/$conversationId/decline');
    _unwrap(res, (_) => null);
  }

  Future<Map<String, dynamic>> createGroup({
    required String title,
    required String avatarColor,
    required List<Map<String, dynamic>> members,
  }) async {
    final res = await _dio.post('/api/conversations/group', data: {
      'title': title,
      'avatarColor': avatarColor,
      'members': members,
    });
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['conversation'] as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> getGroupKey(String conversationId) async {
    final res = await _dio.get('/api/conversations/$conversationId/key');
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  Future<List<dynamic>> listMessages(String conversationId, {String? before}) async {
    final res = await _dio.get(
      '/api/conversations/$conversationId/messages',
      queryParameters: before == null ? null : {'before': before},
    );
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['messages'] as List<dynamic>);
  }

  // ── Uploads (attachments) ──────────────────────────────────────────
  // The bytes handed in/out here are already AES-GCM ciphertext (see
  // core/crypto/keys.dart's encryptFile/decryptFileBytes) — this endpoint
  // just stores/serves opaque blobs, same as public/js/app.js's flow.

  Future<Map<String, dynamic>> uploadBlob(List<int> bytes) async {
    final form = FormData.fromMap({'blob': MultipartFile.fromBytes(bytes, filename: 'blob.bin')});
    final res = await _dio.post('/api/upload', data: form);
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  /// Chat backup: the password-locked file (see core/chat_backup.dart).
  Future<Map<String, dynamic>> putBackup(List<int> bytes, {required int messageCount, required String device}) async {
    final form = FormData.fromMap({
      'blob': MultipartFile.fromBytes(bytes, filename: 'backup.bin'),
      'messageCount': '$messageCount',
      'device': device,
    });
    return _unwrap(await _dio.put('/api/backup', data: form), _asMap);
  }

  Future<List<int>> downloadBlob(String filePath) async {
    final res = await _dio.get<List<int>>(
      '/api/upload/$filePath',
      options: Options(responseType: ResponseType.bytes),
    );
    return _unwrap(res, (d) => d as List<int>);
  }

  // ── Starred messages ────────────────────────────────────────────────

  Future<void> starMessage(String messageId) async {
    final res = await _dio.post('/api/messages/$messageId/star');
    _unwrap(res, (_) => null);
  }

  Future<void> unstarMessage(String messageId) async {
    final res = await _dio.delete('/api/messages/$messageId/star');
    _unwrap(res, (_) => null);
  }

  Future<List<dynamic>> listStarredMessages() async {
    final res = await _dio.get('/api/messages/starred');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['starred'] as List<dynamic>);
  }

  // ── My profile ──────────────────────────────────────────────────────

  /// Name (max 60) and About (max 140). Returns the user row — note the
  /// server leaves `appearance` out of it, so callers keep their own.
  Future<Map<String, dynamic>> updateMe({required String displayName, required String about}) async {
    final res = await _dio.patch('/api/users/me', data: {'displayName': displayName, 'about': about});
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['user'] as Map<String, dynamic>);
  }

  /// Profile photo — JPEG, PNG or WebP, up to 5 MB (server-enforced).
  Future<Map<String, dynamic>> uploadMyPhoto(List<int> bytes, String mime) async {
    final ext = mime == 'image/png' ? 'png' : mime == 'image/webp' ? 'webp' : 'jpg';
    final form = FormData.fromMap({
      'photo': MultipartFile.fromBytes(bytes, filename: 'photo.$ext', contentType: DioMediaType.parse(mime)),
    });
    final res = await _dio.post('/api/users/me/photo', data: form);
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['user'] as Map<String, dynamic>);
  }

  /// PNG of my QR code (content "vesper:user:<my id>").
  Future<List<int>> myQr() => fetchBytes('/api/users/me/qr');

  // ── Chat management (same endpoints as the website's chat menu) ─────

  Future<void> setFavorite(String conversationId, bool favorite) async {
    final res = await _dio.patch('/api/conversations/$conversationId/favorite', data: {'favorite': favorite});
    _unwrap(res, (_) => null);
  }

  /// [hours]: mute for that long (8, 168…); null = always.
  Future<Map<String, dynamic>> setMuted(String conversationId, bool muted, {double? hours}) async {
    final res = await _dio.patch('/api/conversations/$conversationId/mute',
        data: {'muted': muted, if (hours != null) 'hours': hours});
    return _unwrap(res, _asMap);
  }

  /// Pin a chat to the top of my list (up to 3). Returns pinnedAt.
  Future<String?> setPinned(String conversationId, bool pinned) async {
    final res = await _dio.patch('/api/conversations/$conversationId/pin', data: {'pinned': pinned});
    return _unwrap(res, (d) => (d as Map)['pinnedAt'] as String?);
  }

  /// Clears this account's view of the chat only.
  Future<void> clearChat(String conversationId) async {
    final res = await _dio.post('/api/conversations/$conversationId/clear');
    _unwrap(res, (_) => null);
  }

  /// Removes the chat from this account's list (until they message again).
  Future<void> deleteChat(String conversationId) async {
    final res = await _dio.delete('/api/conversations/$conversationId');
    _unwrap(res, (_) => null);
  }

  Future<void> blockUser(String userId) async {
    final res = await _dio.post('/api/users/$userId/block');
    _unwrap(res, (_) => null);
  }

  Future<void> unblockUser(String userId) async {
    final res = await _dio.delete('/api/users/$userId/block');
    _unwrap(res, (_) => null);
  }

  Future<List<dynamic>> listBlocked() async {
    final res = await _dio.get('/api/users/me/blocked');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['users'] as List<dynamic>);
  }

  /// Adds someone to a group with the group key already wrapped for them.
  Future<void> addMember(String conversationId, {required String userId, required String wrappedKey, required String wrappedIv}) async {
    final res = await _dio.post('/api/conversations/$conversationId/members',
        data: {'userId': userId, 'wrappedKey': wrappedKey, 'wrappedIv': wrappedIv});
    _unwrap(res, (_) => null);
  }

  /// Removes a member (owner only) — or leaves, when userId is my own id.
  Future<void> removeMember(String conversationId, String userId) async {
    final res = await _dio.delete('/api/conversations/$conversationId/members/$userId');
    _unwrap(res, (_) => null);
  }

  /// Ids of everyone currently online.
  Future<List<String>> presence() async {
    final res = await _dio.get('/api/presence');
    return _unwrap(res, (d) => ((d as Map<String, dynamic>)['online'] as List<dynamic>).cast<String>());
  }

  /// Any authenticated binary resource by its API path (e.g. a profile
  /// photo's `photoUrl`) — sent with the session cookie, unlike Image.network.
  Future<List<int>> fetchBytes(String path) async {
    final res = await _dio.get<List<int>>(path, options: Options(responseType: ResponseType.bytes));
    return _unwrap(res, (d) => d as List<int>);
  }

  /// `[{id, username, displayName, avatarColor, photoUrl, publicKey, role}]`
  Future<List<dynamic>> listMembers(String conversationId) async {
    final res = await _dio.get('/api/conversations/$conversationId/members');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['members'] as List<dynamic>);
  }

  /// "Delete for me" — hides the message from this account only.
  Future<void> hideMessage(String messageId) async {
    final res = await _dio.post('/api/messages/$messageId/hide');
    _unwrap(res, (_) => null);
  }

  // ── GIFs (Tenor, proxied by the backend) ────────────────────────────

  Future<bool> gifEnabled() async {
    final res = await _dio.get('/api/gif/config');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['enabled'] == true);
  }

  /// `[{url, preview, description}]`; an empty query returns trending GIFs.
  Future<List<dynamic>> searchGifs(String query) async {
    final res = await _dio.get('/api/gif/search', queryParameters: {'q': query});
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['results'] as List<dynamic>);
  }

  /// The GIF's bytes, fetched by the server (so Tenor never sees this phone).
  Future<List<int>> fetchGif(String url) async {
    final res = await _dio.get<List<int>>(
      '/api/gif/fetch',
      queryParameters: {'url': url},
      options: Options(responseType: ResponseType.bytes),
    );
    return _unwrap(res, (d) => d as List<int>);
  }

  // ── Wallpapers ──────────────────────────────────────────────────────

  Future<void> setWallpaper(String conversationId, String? wallpaper) async {
    final res = await _dio.patch('/api/conversations/$conversationId/wallpaper', data: {'wallpaper': wallpaper});
    _unwrap(res, (_) => null);
  }

  Future<void> setWallpaperFit(String conversationId, String fit) async {
    final res = await _dio.patch('/api/conversations/$conversationId/wallpaper-fit', data: {'fit': fit});
    _unwrap(res, (_) => null);
  }

  Future<void> uploadWallpaperPhoto(String conversationId, List<int> bytes, String mimeType) async {
    final form = FormData.fromMap({
      'photo': MultipartFile.fromBytes(bytes, filename: 'wallpaper', contentType: DioMediaType.parse(mimeType)),
    });
    final res = await _dio.post('/api/conversations/$conversationId/wallpaper-photo', data: form);
    _unwrap(res, (_) => null);
  }

  Future<List<int>> downloadWallpaperPhoto(String conversationId) async {
    final res = await _dio.get<List<int>>(
      '/api/conversations/$conversationId/wallpaper-photo',
      options: Options(responseType: ResponseType.bytes),
    );
    return _unwrap(res, (d) => d as List<int>);
  }

  // ── AI chat (local Ollama model behind the backend — not E2E encrypted) ─

  /// `[{id, role: 'user'|'assistant', content, createdAt}]`
  Future<List<dynamic>> aiMessages() async {
    final res = await _dio.get('/api/ai/messages');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['messages'] as List<dynamic>);
  }

  /// Returns the assistant's reply text.
  Future<String> aiSend(String content) async {
    final res = await _dio.post('/api/ai/message',
        data: {'content': content}, options: Options(receiveTimeout: const Duration(seconds: 90)));
    return _unwrap(res, (d) => ((d as Map<String, dynamic>)['assistantMessage'] as Map<String, dynamic>)['content'] as String);
  }

  // ── Custom chat lists (labels) ──────────────────────────────────────

  /// `[{id, name, color, conversationIds}]`
  Future<List<dynamic>> listLabels() async {
    final res = await _dio.get('/api/labels');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['labels'] as List<dynamic>);
  }

  Future<Map<String, dynamic>> createLabel(String name, {String? color}) async {
    final res = await _dio.post('/api/labels', data: {'name': name, if (color != null) 'color': color});
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['label'] as Map<String, dynamic>);
  }

  Future<void> deleteLabel(String labelId) async {
    final res = await _dio.delete('/api/labels/$labelId');
    _unwrap(res, (_) => null);
  }

  /// Adds the chat to the list, or removes it if it's already there.
  Future<bool> toggleLabel(String labelId, String conversationId) async {
    final res = await _dio.post('/api/labels/$labelId/toggle', data: {'conversationId': conversationId});
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['applied'] == true);
  }

  // ── Scheduled messages ──────────────────────────────────────────────

  /// `[{id, ciphertext, iv, sendAt, sentAt, createdAt}]` — mine, not yet sent.
  Future<List<dynamic>> listScheduled(String conversationId) async {
    final res = await _dio.get('/api/conversations/$conversationId/scheduled-messages');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['scheduledMessages'] as List<dynamic>);
  }

  Future<void> scheduleMessage(String conversationId, {required String ciphertext, required String iv, required DateTime sendAt}) async {
    final res = await _dio.post('/api/conversations/$conversationId/scheduled-messages',
        data: {'ciphertext': ciphertext, 'iv': iv, 'sendAt': sendAt.toUtc().toIso8601String()});
    _unwrap(res, (_) => null);
  }

  Future<void> cancelScheduled(String conversationId, String id) async {
    final res = await _dio.delete('/api/conversations/$conversationId/scheduled-messages/$id');
    _unwrap(res, (_) => null);
  }

  // ── Voice note → text (local Whisper service behind the backend) ────

  Future<String> transcribe(List<int> audio, {required String filename, required String mime}) async {
    final form = FormData.fromMap({
      'audio': MultipartFile.fromBytes(audio, filename: filename, contentType: DioMediaType.parse(mime)),
    });
    final res = await _dio.post('/api/voice/transcribe', data: form, options: Options(receiveTimeout: const Duration(seconds: 90)));
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['text'] as String);
  }

  // ── Status / Stories ────────────────────────────────────────────────

  Future<Map<String, dynamic>> postStatus(Map<String, dynamic> body) async {
    final res = await _dio.post('/api/status', data: body);
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['status'] as Map<String, dynamic>);
  }

  Future<List<dynamic>> listStatuses() async {
    final res = await _dio.get('/api/status');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['statuses'] as List<dynamic>);
  }

  Future<void> viewStatus(String statusId) async {
    final res = await _dio.post('/api/status/$statusId/view');
    _unwrap(res, (_) => null);
  }

  Future<List<dynamic>> statusViews(String statusId) async {
    final res = await _dio.get('/api/status/$statusId/views');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['views'] as List<dynamic>);
  }

  Future<void> deleteStatus(String statusId) async {
    final res = await _dio.delete('/api/status/$statusId');
    _unwrap(res, (_) => null);
  }

  // ── Device linking (QR) ─────────────────────────────────────────────

  Future<Map<String, dynamic>> linkStart({required Map<String, dynamic> ephemeralPublicKey, required String deviceSecret}) async {
    final res = await _dio.post('/api/link/start', data: {'ephemeralPublicKey': ephemeralPublicKey, 'deviceSecret': deviceSecret});
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> linkClaim(String code) async {
    final res = await _dio.post('/api/link/claim', data: {'code': code});
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  Future<void> linkComplete({required String code, required String wrappedKey, required String wrappedIv}) async {
    final res = await _dio.post('/api/link/complete', data: {'code': code, 'wrappedKey': wrappedKey, 'wrappedIv': wrappedIv});
    _unwrap(res, (_) => null);
  }

  /// Returns {status: 'pending'} or {status: 'ready', wrappedKey, wrappedIv,
  /// publicKey, user} -- a 'ready' response also sets the session cookie
  /// server-side (this IS effectively "log me in" for the new device).
  Future<Map<String, dynamic>> linkPoll({required String code, required String deviceSecret}) async {
    final res = await _dio.post('/api/link/poll', data: {'code': code, 'deviceSecret': deviceSecret});
    return _unwrap(res, (d) => d as Map<String, dynamic>);
  }

  Future<void> linkCancel(String code) async {
    final res = await _dio.post('/api/link/cancel', data: {'code': code});
    _unwrap(res, (_) => null);
  }

  // ── Reminders ───────────────────────────────────────────────────────

  Future<List<dynamic>> listReminders() async {
    final res = await _dio.get('/api/reminders');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['reminders'] as List<dynamic>);
  }

  Future<Map<String, dynamic>> createReminder({required String content, required String category, required String remindAt}) async {
    final res = await _dio.post('/api/reminders', data: {'content': content, 'category': category, 'remindAt': remindAt});
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['reminder'] as Map<String, dynamic>);
  }

  Future<void> deleteReminder(String id) async {
    final res = await _dio.delete('/api/reminders/$id');
    _unwrap(res, (_) => null);
  }

  // ── Appearance ──────────────────────────────────────────────────────

  Future<Map<String, dynamic>> updateAppearance({String? palette, String? mode, String? structure}) async {
    final res = await _dio.patch('/api/users/me/appearance', data: {
      if (palette != null) 'palette': palette,
      if (mode != null) 'mode': mode,
      if (structure != null) 'structure': structure,
    });
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['appearance'] as Map<String, dynamic>);
  }

  // ── Users ───────────────────────────────────────────────────────────

  Future<List<dynamic>> searchUsers(String query) async {
    final res = await _dio.get('/api/users', queryParameters: {'q': query});
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['users'] as List<dynamic>);
  }

  Future<Map<String, dynamic>> getUser(String userId) async {
    final res = await _dio.get('/api/users/$userId');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['user'] as Map<String, dynamic>);
  }

  // ── AI helpers on chat text (decrypted here; nothing is stored) ─────

  static final _aiTimeout = Options(receiveTimeout: const Duration(seconds: 100));

  /// `lines`: `[{name, text}]`, oldest first.
  Future<String> aiSummarize(List<Map<String, String>> lines) async {
    final res = await _dio.post('/api/ai/summarize', data: {'lines': lines}, options: _aiTimeout);
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['summary'] as String);
  }

  Future<String> aiTranslate(String text, String to) async {
    final res = await _dio.post('/api/ai/translate', data: {'text': text, 'to': to}, options: _aiTimeout);
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['translation'] as String);
  }

  Future<List<String>> aiReplies(List<Map<String, String>> lines, String me) async {
    final res = await _dio.post('/api/ai/replies', data: {'lines': lines, 'me': me}, options: _aiTimeout);
    return _unwrap(res, (d) => ((d as Map<String, dynamic>)['replies'] as List<dynamic>).cast<String>());
  }

  // ── Security & logins ───────────────────────────────────────────────

  /// `[{id, device, ip, method, createdAt}]`, newest first.
  Future<List<dynamic>> recentLogins() async {
    final res = await _dio.get('/api/auth/logins');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['logins'] as List<dynamic>);
  }

  /// Signs out every other device; this one gets a fresh session cookie.
  Future<void> logoutOthers() async {
    final res = await _dio.post('/api/auth/logout-others');
    _unwrap(res, (_) => null);
  }

  // ── Quick replies ───────────────────────────────────────────────────

  Future<List<dynamic>> listQuickReplies() async {
    final res = await _dio.get('/api/quick-replies');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['replies'] as List<dynamic>);
  }

  Future<Map<String, dynamic>> saveQuickReply({String? id, required String shortcut, required String body}) async {
    final data = {'shortcut': shortcut, 'body': body};
    final res = id == null ? await _dio.post('/api/quick-replies', data: data) : await _dio.patch('/api/quick-replies/$id', data: data);
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['reply'] as Map<String, dynamic>);
  }

  Future<void> deleteQuickReply(String id) async {
    final res = await _dio.delete('/api/quick-replies/$id');
    _unwrap(res, (_) => null);
  }

  // ── Broadcast lists ─────────────────────────────────────────────────

  /// `[{id, name, memberIds, createdAt}]`
  Future<List<dynamic>> listBroadcasts() async {
    final res = await _dio.get('/api/broadcasts');
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['lists'] as List<dynamic>);
  }

  Future<Map<String, dynamic>> saveBroadcast({String? id, required String name, required List<String> memberIds}) async {
    final data = {'name': name, 'memberIds': memberIds};
    final res = id == null ? await _dio.post('/api/broadcasts', data: data) : await _dio.put('/api/broadcasts/$id', data: data);
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['list'] as Map<String, dynamic>);
  }

  Future<void> deleteBroadcast(String id) async {
    final res = await _dio.delete('/api/broadcasts/$id');
    _unwrap(res, (_) => null);
  }

  // ── Business profile ────────────────────────────────────────────────

  /// Returns my saved business settings.
  Future<Map<String, dynamic>> updateBusiness(Map<String, dynamic> business) async {
    final res = await _dio.patch('/api/users/me/business', data: business);
    return _unwrap(res, (d) => (d as Map<String, dynamic>)['businessSettings'] as Map<String, dynamic>);
  }

  /// The session cookie value, needed to authenticate the WebSocket
  /// handshake by hand (see ws_client.dart) since web_socket_channel
  /// doesn't share Dio's cookie jar automatically.
  Future<String?> sessionCookieHeader() async {
    final uri = Uri.parse(baseUrl);
    final cookies = await cookieJar.loadForRequest(uri);
    if (cookies.isEmpty) return null;
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }
}
