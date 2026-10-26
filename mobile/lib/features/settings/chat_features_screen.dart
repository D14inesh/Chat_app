/// "Chat features" — notifications (saved on the account, so every device
/// follows them), plus this phone's switches for auto voice-to-text,
/// message effects, and the language Translate uses.
library chat_features_screen;

import '../../theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../auth/session.dart';

import '../../core/prefs_store.dart';
import '../chat/chat_extras.dart';

class ChatFeaturesScreen extends ConsumerWidget {
  const ChatFeaturesScreen({super.key});

  Future<void> _setNotify(BuildContext context, WidgetRef ref, {bool? messages, bool? calls}) async {
    final session = ref.read(sessionControllerProvider);
    try {
      final res = await session.api.patchJson('/api/push/settings', {
        if (messages != null) 'messages': messages,
        if (calls != null) 'calls': calls,
      });
      await ref.read(sessionControllerProvider.notifier)
          .updateNotify(messages: res['messages'] == true, calls: res['calls'] == true);
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not reach the server — try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = PrefsStore.instance;
    final user = ref.watch(sessionControllerProvider.select((s) => s.user));
    return Scaffold(
      appBar: AppBar(title: const Text('Chat features')),
      body: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text('Notifications — for every device you use.', style: TextStyle(color: VeyonColors.muted)),
            ),
            Card(
              child: SwitchListTile(
                value: user?.notifyMessages ?? true,
                onChanged: (v) => _setNotify(context, ref, messages: v),
                secondary: const Text('🔔', style: TextStyle(fontSize: 22)),
                title: const Text('Message notifications', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Who sent it and what — text, photo, voice message…'),
              ),
            ),
            Card(
              child: SwitchListTile(
                value: user?.notifyCalls ?? true,
                onChanged: (v) => _setNotify(context, ref, calls: v),
                secondary: const Text('📞', style: TextStyle(fontSize: 22)),
                title: const Text('Call notifications', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Incoming voice and video calls'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 14, 4, 10),
              child: Text('Settings for this phone.', style: TextStyle(color: VeyonColors.muted)),
            ),
            Card(
              child: SwitchListTile(
                value: prefs.autoTranscribe,
                onChanged: (v) => prefs.autoTranscribe = v,
                secondary: const Text('🎤', style: TextStyle(fontSize: 22)),
                title: const Text('Auto voice-to-text', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Show the text of voice messages under them automatically (uses your server’s speech service)'),
              ),
            ),
            Card(
              child: SwitchListTile(
                value: prefs.effects,
                onChanged: (v) => prefs.effects = v,
                secondary: const Text('🎉', style: TextStyle(fontSize: 22)),
                title: const Text('Message effects', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Confetti, balloons and hearts for “Happy birthday”, “Congratulations” and “Love you”'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Text('🌐', style: TextStyle(fontSize: 22)),
                title: const Text('Translate messages to', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Used by Translate on a message'),
                trailing: Text('${kLanguages[prefs.translateTo] ?? 'English'} ›',
                    style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.w700)),
                onTap: () async {
                  final code = await pickLanguage(context, prefs.translateTo);
                  if (code != null) prefs.translateTo = code;
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
