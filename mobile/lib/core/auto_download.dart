/// Automatic download (Storage & data): whether photos, voice notes and
/// videos download on their own when a chat shows them, or wait for a tap.
/// Saves mobile data and phone storage — WhatsApp's "Media auto-download".
library auto_download;

import 'package:connectivity_plus/connectivity_plus.dart';

import 'prefs_store.dart';

/// 'always' (Wi-Fi and mobile data) | 'wifi' (Wi-Fi only) | 'never' (tap to download).
const autoDownloadChoices = [
  ('always', 'Wi-Fi and mobile data'),
  ('wifi', 'Wi-Fi only'),
  ('never', 'Never (tap to download)'),
];

/// (kind, label, default) in the order the Storage screen lists them.
const autoDownloadKinds = [
  ('photos', 'Photos', 'always'),
  ('voice', 'Voice notes', 'always'),
  ('videos', 'Videos', 'wifi'),
];

String autoDownloadSetting(String kind) {
  final raw = PrefsStore.instance.get('autoDownload');
  final value = raw is Map ? raw[kind] : null;
  if (value is String) return value;
  return autoDownloadKinds.firstWhere((k) => k.$1 == kind, orElse: () => (kind, '', 'always')).$3;
}

void setAutoDownload(String kind, String value) {
  final raw = PrefsStore.instance.get('autoDownload');
  PrefsStore.instance.put('autoDownload', {...(raw is Map ? Map<String, dynamic>.from(raw) : {}), kind: value});
}

/// Should a [kind] file download now, without a tap?
Future<bool> shouldAutoDownload(String kind) async {
  switch (autoDownloadSetting(kind)) {
    case 'never':
      return false;
    case 'wifi':
      try {
        final now = await Connectivity().checkConnectivity();
        return now.contains(ConnectivityResult.wifi) || now.contains(ConnectivityResult.ethernet);
      } catch (_) {
        return false;
      }
    default:
      return true;
  }
}
