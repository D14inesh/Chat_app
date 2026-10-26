/// Server base URL — the live server by default, so a plain
/// `flutter build apk` always produces an APK that works on real phones.
/// Override at build time to test against something else, e.g. a PC on the
/// same Wi-Fi or the Android emulator (10.0.2.2 = the host's localhost):
///   flutter run --dart-define=VEYON_API_BASE_URL=http://192.168.1.5:4100
///
/// HTTPS uses the server's self-signed certificate (accepted by
/// ApiClient/WsClient); ws:// / wss:// follow automatically.
class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'VEYON_API_BASE_URL',
    defaultValue: 'https://api.shutup.live',
  );

  static String get wsBaseUrl => apiBaseUrl.replaceFirst('http', 'ws');

  /// The website (group invite links open it). Defaults to the same host on
  /// the website's HTTPS port.
  static const String webBaseUrl = String.fromEnvironment(
    'VEYON_WEB_BASE_URL',
    defaultValue: 'https://103.207.3.66:5843',
  );
}
