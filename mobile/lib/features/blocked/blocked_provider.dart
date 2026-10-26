/// The people I've blocked — loaded from the server, cached on the phone
/// (so the "You blocked this contact" bar shows offline too), and changed
/// via block/unblock. Same data as the website's "Blocked contacts" panel.
library blocked_provider;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/user.dart';
import '../auth/session.dart';

class BlockedController extends StateNotifier<List<AppUser>> {
  final Session _session;

  BlockedController(this._session) : super(const []) {
    _init();
  }

  Set<String> get ids => state.map((u) => u.id).toSet();

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/veyon_cache/blocked.json');
  }

  Future<void> _init() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        state = (jsonDecode(await f.readAsString()) as List<dynamic>)
            .map((j) => AppUser.fromJson(j as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
    await refresh();
  }

  Future<void> refresh() async {
    try {
      final users = (await _session.api.listBlocked()).map((j) => AppUser.fromJson(j as Map<String, dynamic>)).toList();
      state = users;
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(users.map((u) => u.toJson()).toList()));
    } catch (_) {
      // offline — keep the saved list
    }
  }

  Future<void> block(AppUser user) async {
    await _session.api.blockUser(user.id);
    state = [user, ...state.where((u) => u.id != user.id)];
    await refresh();
  }

  Future<void> unblock(String userId) async {
    await _session.api.unblockUser(userId);
    state = state.where((u) => u.id != userId).toList();
    await refresh();
  }
}

final blockedProvider = StateNotifierProvider<BlockedController, List<AppUser>>((ref) {
  return BlockedController(ref.watch(sessionControllerProvider));
});
