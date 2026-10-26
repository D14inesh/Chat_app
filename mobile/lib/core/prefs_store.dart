/// Small on-device settings and per-chat drafts, kept in one JSON file in
/// the app's private folder. Loaded once at startup ([PrefsStore.load]);
/// reads are synchronous after that, writes are saved in the background.
/// Nothing here is ever required for the app to work.
library prefs_store;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class PrefsStore extends ChangeNotifier {
  PrefsStore._();
  static final PrefsStore instance = PrefsStore._();

  Map<String, dynamic> _data = {};
  bool _loaded = false;
  Timer? _saveTimer;

  static const _defaults = {'autoTranscribe': false, 'effects': true, 'translateTo': 'en'};

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) _data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      _data = {};
    }
    notifyListeners();
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/veyon_prefs.json');
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        await (await _file()).writeAsString(jsonEncode(_data));
      } catch (_) {/* storage full — the setting just won't stick */}
    });
  }

  // ── Settings ──
  bool get autoTranscribe => (_data['autoTranscribe'] ?? _defaults['autoTranscribe']) as bool;
  set autoTranscribe(bool v) => _set('autoTranscribe', v);

  bool get effects => (_data['effects'] ?? _defaults['effects']) as bool;
  set effects(bool v) => _set('effects', v);

  String get translateTo => (_data['translateTo'] ?? _defaults['translateTo']) as String;
  set translateTo(String v) => _set('translateTo', v);

  /// Voice message playback speed (1, 1.5 or 2).
  double get voiceSpeed => ((_data['voiceSpeed'] as num?) ?? 1).toDouble();
  set voiceSpeed(double v) => _set('voiceSpeed', v);

  /// Any other small setting (ringtone per contact, my stickers…).
  Object? get(String key) => _data[key];
  void put(String key, Object value) => _set(key, value);

  void _set(String key, Object value) {
    _data[key] = value;
    _save();
    notifyListeners();
  }

  // ── Drafts (per conversation) ──
  Map<String, dynamic> get _drafts => (_data['drafts'] as Map<String, dynamic>?) ?? {};

  String draftFor(String conversationId) => _drafts[conversationId] as String? ?? '';

  void setDraft(String conversationId, String text) {
    final drafts = Map<String, dynamic>.from(_drafts);
    final had = drafts.containsKey(conversationId);
    if (text.trim().isEmpty) {
      drafts.remove(conversationId);
    } else {
      drafts[conversationId] = text;
    }
    _data['drafts'] = drafts;
    _save();
    if (had != drafts.containsKey(conversationId)) notifyListeners();
  }

  void clearDraft(String conversationId) => setDraft(conversationId, '');
}
