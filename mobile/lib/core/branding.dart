import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/session.dart';

/// The app name + logo the owner sets in the admin app (GET /api/branding).
class Branding {
  final String name;
  final Uint8List? logo;
  final int version;
  const Branding({this.name = 'Veyon Chat', this.logo, this.version = -1});
}

/// Checked every 15 s (and once at start), so a change made in the admin
/// shows up in the running app within seconds. The logo is only re-downloaded
/// when the version changes.
final brandingProvider = StreamProvider<Branding>((ref) async* {
  final api = await ref.watch(apiClientProvider.future);
  var disposed = false;
  ref.onDispose(() => disposed = true);
  var cur = const Branding();
  yield cur;
  while (!disposed) {
    try {
      final j = await api.getJson('/api/branding');
      final v = (j['v'] as num?)?.toInt() ?? 0;
      if (v != cur.version) {
        final url = j['logoUrl'] as String?;
        cur = Branding(
          name: (j['name'] as String?) ?? cur.name,
          logo: url == null ? null : await api.getBytes(url),
          version: v,
        );
        yield cur;
      }
    } catch (_) {/* offline — keep what is shown */}
    await Future<void>.delayed(const Duration(seconds: 15));
  }
});
