import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/prefs_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PrefsStore.instance.load(); // drafts + chat-feature switches (tiny file)
  runApp(const ProviderScope(child: VeyonApp()));
}
