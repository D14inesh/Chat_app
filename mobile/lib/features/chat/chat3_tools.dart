/// Edit history, chat lock and stickers from your photos — the phone side
/// of the website's js/features/chat3.js.
library chat3_tools;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api_client.dart';
import '../../core/crypto/keys.dart';
import '../../models/conversation.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';

String _err(Object e) => e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), '');

String _when(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes} min ago';
  if (diff.inDays < 1) return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  return '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

// ── Edit history ────────────────────────────────────────────

Future<void> showEditHistory(BuildContext context, ApiClient api, SecretKey? key, String messageId) async {
  if (key == null) return;
  List<Map<String, dynamic>> versions;
  try {
    versions = ((await api.getJson('/api/messages/$messageId/edits'))['versions'] as List).cast<Map<String, dynamic>>();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    return;
  }
  final texts = <String?>[];
  for (final v in versions) {
    try {
      texts.add(await decryptText(key, v['ciphertext'] as String, v['iv'] as String));
    } catch (_) {
      texts.add(null);
    }
  }
  if (!context.mounted) return;
  final accent = Theme.of(context).colorScheme.secondary;
  final items = [for (var i = versions.length - 1; i >= 0; i--) (versions[i], texts[i], i)];
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(18, 0, 18, 18), children: [
          const Text('Edit history', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          for (final (v, text, i) in items)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border(left: BorderSide(color: v['current'] == true ? accent : Colors.white24, width: 3)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(v['current'] == true ? 'NOW' : i == 0 ? 'ORIGINAL' : 'EDITED',
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Colors.white60, letterSpacing: 0.4)),
                  const Spacer(),
                  Text(_when(v['at'] as String?), style: const TextStyle(fontSize: 11.5, color: Colors.white38)),
                ]),
                const SizedBox(height: 4),
                Text(text ?? 'Couldn’t decrypt', style: TextStyle(fontStyle: text == null ? FontStyle.italic : null)),
              ]),
            ),
        ]),
      ),
    ),
  );
}

// ── Chat lock ───────────────────────────────────────────────
// One PIN per account (checked by the server). Locked chats hide behind a
// "Locked chats" row; the PIN (or fingerprint) opens them for 5 minutes.

class ChatLockState {
  final bool? hasPin;
  final DateTime? openUntil;
  const ChatLockState({this.hasPin, this.openUntil});
  bool get open => openUntil != null && DateTime.now().isBefore(openUntil!);
}

class ChatLockController extends StateNotifier<ChatLockState> {
  final Ref ref;
  ChatLockController(this.ref) : super(const ChatLockState());

  ApiClient get _api => ref.read(sessionControllerProvider).api;

  Future<bool> hasPin() async {
    if (state.hasPin != null) return state.hasPin!;
    try {
      final v = (await _api.getJson('/api/chat-lock'))['hasPin'] == true;
      state = ChatLockState(hasPin: v, openUntil: state.openUntil);
      return v;
    } catch (_) {
      return false;
    }
  }

  void opened() => state = ChatLockState(hasPin: true, openUntil: DateTime.now().add(const Duration(minutes: 5)));
  void relock() => state = ChatLockState(hasPin: state.hasPin);
  void setHasPin(bool v) => state = ChatLockState(hasPin: v, openUntil: state.openUntil);
}

final chatLockProvider = StateNotifierProvider<ChatLockController, ChatLockState>((ref) => ChatLockController(ref));

/// A PIN dialog; `check` returns an error message or null when accepted.
Future<String?> _pinDialog(BuildContext context, {
  required String title,
  required String subtitle,
  bool confirm = false,
  bool current = false,
  bool offerBiometric = false,
  required Future<String?> Function(String pin, String? currentPin) check,
}) {
  final cur = TextEditingController();
  final p1 = TextEditingController();
  final p2 = TextEditingController();
  String? error;
  bool busy = false;
  Widget field(TextEditingController c, String label, {bool focus = false}) => TextField(
        controller: c,
        autofocus: focus,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 22, letterSpacing: 8),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label, counterText: ''),
      );
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        icon: Icon(Icons.lock_rounded, color: Theme.of(ctx).colorScheme.secondary),
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          if (error != null)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(error!, style: const TextStyle(color: VeyonColors.danger))),
          if (current) field(cur, 'Current PIN', focus: true),
          field(p1, confirm ? 'New PIN (4–8 digits)' : 'PIN', focus: !current),
          if (confirm) field(p2, 'Type it again'),
          if (offerBiometric)
            TextButton.icon(
              onPressed: () async {
                try {
                  final ok = await LocalAuthentication().authenticate(localizedReason: 'Open locked chats');
                  if (ok && ctx.mounted) Navigator.pop(ctx, '__bio__');
                } catch (_) {
                  setD(() => error = 'Fingerprint isn’t available — use your PIN.');
                }
              },
              icon: const Icon(Icons.fingerprint_rounded),
              label: const Text('Use fingerprint'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final pin = p1.text;
                    if (confirm && pin != p2.text) return setD(() => error = 'The two PINs don’t match.');
                    if (pin.length < 4) return setD(() => error = 'The PIN must be 4–8 digits.');
                    setD(() => busy = true);
                    final e = await check(pin, current ? cur.text : null);
                    if (!ctx.mounted) return;
                    if (e == null) {
                      Navigator.pop(ctx, pin);
                    } else {
                      setD(() {
                        error = e;
                        busy = false;
                      });
                    }
                  },
            child: Text(confirm ? 'Save PIN' : 'Unlock'),
          ),
        ],
      ),
    ),
  );
}

Future<bool> _biometricAvailable() async {
  try {
    final auth = LocalAuthentication();
    return await auth.canCheckBiometrics && await auth.isDeviceSupported();
  } catch (_) {
    return false;
  }
}

Future<bool> unlockLockedChats(BuildContext context, WidgetRef ref) async {
  final api = ref.read(sessionControllerProvider).api;
  final bio = await _biometricAvailable();
  if (!context.mounted) return false;
  final r = await _pinDialog(context, title: 'Locked chats', subtitle: 'Enter your chat lock PIN.', offerBiometric: bio, check: (pin, _) async {
    try {
      await api.postJson('/api/chat-lock/verify', {'pin': pin});
      return null;
    } catch (e) {
      return _err(e);
    }
  });
  if (r == null) return false;
  ref.read(chatLockProvider.notifier).opened();
  return true;
}

Future<bool> _setUpPin(BuildContext context, WidgetRef ref) async {
  final api = ref.read(sessionControllerProvider).api;
  final r = await _pinDialog(context,
      title: 'Set a chat lock PIN',
      subtitle: 'Locked chats stay hidden until this PIN is entered — on every device you use.',
      confirm: true, check: (pin, _) async {
    try {
      await api.postJson('/api/chat-lock/pin', {'pin': pin});
      return null;
    } catch (e) {
      return _err(e);
    }
  });
  if (r == null) return false;
  ref.read(chatLockProvider.notifier).setHasPin(true);
  return true;
}

/// Lock a chat (sets up the PIN the first time), or take it out (PIN needed).
/// Returns true when the chat is now locked.
Future<bool?> toggleChatLock(BuildContext context, WidgetRef ref, Conversation c) async {
  final api = ref.read(sessionControllerProvider).api;
  final conversations = ref.read(conversationsProvider.notifier);
  // All 1-to-1 chats are already behind the PIN — manage that setting instead.
  if (!c.isGroup && (ref.read(sessionControllerProvider).user?.privateLock ?? false)) {
    await openChatLockSettings(context, ref);
    return null;
  }
  if (!c.locked) {
    if (!await ref.read(chatLockProvider.notifier).hasPin()) {
      if (!context.mounted || !await _setUpPin(context, ref)) return null;
    }
    try {
      await api.patchJson('/api/conversations/${c.id}/lock', {'locked': true});
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
      return null;
    }
    await conversations.refresh();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chat locked. Find it under “Locked chats” at the top of your chats.')));
    }
    return true;
  }
  if (!context.mounted) return null;
  final r = await _pinDialog(context, title: 'Remove chat lock', subtitle: 'Enter your PIN to unlock this chat.', check: (pin, _) async {
    try {
      await api.patchJson('/api/conversations/${c.id}/lock', {'locked': false, 'pin': pin});
      return null;
    } catch (e) {
      return _err(e);
    }
  });
  if (r == null) return null;
  await conversations.refresh();
  return false;
}

Future<void> openChatLockSettings(BuildContext context, WidgetRef ref) async {
  final api = ref.read(sessionControllerProvider).api;
  if (!await ref.read(chatLockProvider.notifier).hasPin()) {
    if (!context.mounted || !await _setUpPin(context, ref)) return;
  }
  if (!context.mounted) return;
  final privateOn = ref.read(sessionControllerProvider).user?.privateLock ?? false;
  final act = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(
          leading: Icon(Icons.lock_rounded),
          title: Text('Chat lock', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('Locked chats hide behind “Locked chats” and your PIN. Lock one chat from its ⋮ menu, or all 1-to-1 chats below.'),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.person_outline_rounded),
          value: privateOn,
          onChanged: (_) => Navigator.pop(ctx, privateOn ? 'private-off' : 'private-on'),
          title: const Text('Private chats PIN'),
          subtitle: const Text('Every 1-to-1 chat needs your PIN to open', style: TextStyle(color: Colors.white54)),
        ),
        ListTile(leading: const Icon(Icons.password_rounded), title: const Text('Change PIN'), onTap: () => Navigator.pop(ctx, 'change')),
        ListTile(
          leading: const Icon(Icons.lock_open_rounded, color: VeyonColors.danger),
          title: const Text('Turn off chat lock', style: TextStyle(color: VeyonColors.danger)),
          onTap: () => Navigator.pop(ctx, 'off'),
        ),
      ]),
    ),
  );
  if (act == null || !context.mounted) return;
  if (act == 'private-on' || act == 'private-off') {
    final on = act == 'private-on';
    if (on) {
      try {
        await api.patchJson('/api/chat-lock/private', {'enabled': true});
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
        return;
      }
    } else {
      final r = await _pinDialog(context, title: 'Turn off private chats PIN', subtitle: 'Enter your PIN.', check: (pin, _) async {
        try {
          await api.patchJson('/api/chat-lock/private', {'enabled': false, 'pin': pin});
          return null;
        } catch (e) {
          return _err(e);
        }
      });
      if (r == null) return;
    }
    await ref.read(sessionControllerProvider.notifier).updatePrivateLock(on);
    ref.read(chatLockProvider.notifier).relock();
    await ref.read(conversationsProvider.notifier).refresh();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(on ? 'Your 1-to-1 chats are now behind your PIN.' : 'Private chats PIN is off.')));
    }
    return;
  }
  if (act == 'change') {
    final r = await _pinDialog(context, title: 'Change PIN', subtitle: 'Your current PIN, then the new one.', confirm: true, current: true,
        check: (pin, cur) async {
      try {
        await api.postJson('/api/chat-lock/pin', {'pin': pin, 'currentPin': cur});
        return null;
      } catch (e) {
        return _err(e);
      }
    });
    if (r != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN changed.')));
  } else {
    final r = await _pinDialog(context, title: 'Turn off chat lock', subtitle: 'Every locked chat goes back to your normal list.',
        check: (pin, _) async {
      try {
        await api.deleteJsonWithBody('/api/chat-lock/pin', {'pin': pin});
        return null;
      } catch (e) {
        return _err(e);
      }
    });
    if (r == null) return;
    ref.read(chatLockProvider.notifier).setHasPin(false);
    await ref.read(conversationsProvider.notifier).refresh();
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chat lock is off.')));
  }
}

/// The row above the chat list.
class LockedChatsRow extends ConsumerWidget {
  final int count;
  final int unread;
  const LockedChatsRow({super.key, required this.count, required this.unread});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(chatLockProvider).open;
    final accent = Theme.of(context).colorScheme.secondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Material(
        color: Colors.white.withValues(alpha: 0.04),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: open ? accent.withValues(alpha: 0.4) : Colors.white24),
        ),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: CircleAvatar(backgroundColor: accent.withValues(alpha: 0.15), child: Icon(Icons.lock_rounded, color: accent, size: 20)),
          title: Text(open ? 'Locked chats are showing' : 'Locked chats', style: const TextStyle(fontWeight: FontWeight.w700)),
          trailing: open
              ? TextButton(onPressed: () => ref.read(chatLockProvider.notifier).relock(), child: const Text('Lock'))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('$count', style: const TextStyle(color: Colors.white54)),
                  if (unread > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(99)),
                      child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ]),
          onTap: open ? null : () => unlockLockedChats(context, ref),
        ),
      ),
    );
  }
}

// ── Stickers from your photos ───────────────────────────────

Future<Directory> _stickerDir() async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}/my_stickers');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

Future<List<File>> myStickers() async {
  final files = (await _stickerDir()).listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList();
  files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return files.take(40).toList();
}

Future<void> saveMySticker(Uint8List png) async {
  final d = await _stickerDir();
  await File('${d.path}/${DateTime.now().millisecondsSinceEpoch}.png').writeAsBytes(png);
}

/// Crop / shape / caption a photo; pops with the finished PNG.
class StickerMakerScreen extends StatefulWidget {
  final Uint8List image;
  const StickerMakerScreen({super.key, required this.image});
  @override
  State<StickerMakerScreen> createState() => _StickerMakerScreenState();
}

class _StickerMakerScreenState extends State<StickerMakerScreen> {
  final _key = GlobalKey();
  final _caption = TextEditingController();
  Offset _offset = Offset.zero;
  double _zoom = 1;
  double _startZoom = 1;
  Offset _startFocal = Offset.zero;
  Offset _startOffset = Offset.zero;
  String _shape = 'rounded';
  Color _textColor = Colors.white;
  bool _outline = true;
  bool _busy = false;

  Future<void> _done() async {
    setState(() => _busy = true);
    try {
      final boundary = _key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 512 / boundary.size.width);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      await saveMySticker(png);
      if (mounted) Navigator.pop(context, png);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final size = math.min(MediaQuery.of(context).size.width - 48, 320.0);
    final radius = switch (_shape) { 'circle' => size / 2, 'rounded' => size * 0.18, _ => 0.0 };
    final pad = _outline ? size * 0.028 : 0.0;
    return Scaffold(
      appBar: AppBar(title: const Text('Make a sticker'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: FilledButton.icon(
            onPressed: _busy ? null : _done,
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('Send'),
          ),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Center(
          child: GestureDetector(
            onScaleStart: (d) {
              _startZoom = _zoom;
              _startFocal = d.focalPoint;
              _startOffset = _offset;
            },
            onScaleUpdate: (d) => setState(() {
              _zoom = (_startZoom * d.scale).clamp(1.0, 4.0);
              _offset = _startOffset + (d.focalPoint - _startFocal);
            }),
            child: RepaintBoundary(
              key: _key,
              child: SizedBox(
                width: size,
                height: size,
                child: Container(
                  padding: EdgeInsets.all(pad),
                  decoration: BoxDecoration(color: _outline ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(radius)),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(math.max(0, radius - pad)),
                    child: Stack(fit: StackFit.expand, children: [
                      ClipRect(
                        child: Transform.translate(
                          offset: _offset,
                          child: Transform.scale(scale: _zoom, child: Image.memory(widget.image, fit: BoxFit.cover)),
                        ),
                      ),
                      if (_caption.text.trim().isNotEmpty)
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: size * 0.07,
                          child: Stack(alignment: Alignment.center, children: [
                            Text(
                              _caption.text.toUpperCase(),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: size * 0.12,
                                fontWeight: FontWeight.w900,
                                foreground: Paint()
                                  ..style = PaintingStyle.stroke
                                  ..strokeWidth = size * 0.022
                                  ..strokeJoin = StrokeJoin.round
                                  ..color = _textColor == Colors.black ? Colors.white : Colors.black,
                              ),
                            ),
                            Text(_caption.text.toUpperCase(),
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: size * 0.12, fontWeight: FontWeight.w900, color: _textColor)),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Center(child: Text('Pinch to zoom · drag to move', style: TextStyle(color: Colors.white54, fontSize: 12))),
        const SizedBox(height: 18),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'square', icon: Icon(Icons.crop_square_rounded), label: Text('Square')),
            ButtonSegment(value: 'rounded', icon: Icon(Icons.rounded_corner_rounded), label: Text('Rounded')),
            ButtonSegment(value: 'circle', icon: Icon(Icons.circle_outlined), label: Text('Circle')),
          ],
          selected: {_shape},
          onSelectionChanged: (s) => setState(() => _shape = s.first),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _caption,
              maxLength: 24,
              decoration: const InputDecoration(labelText: 'Caption (optional)', counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
          ),
          for (final c in const [Colors.white, Colors.black, Color(0xFFFFD43B)])
            GestureDetector(
              onTap: () => setState(() => _textColor = c),
              child: Container(
                margin: const EdgeInsets.only(left: 8),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: _textColor == c ? accent : Colors.white30, width: _textColor == c ? 3 : 1.5),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _outline,
          onChanged: (v) => setState(() => _outline = v),
          title: const Text('White outline'),
          subtitle: const Text('The classic sticker look', style: TextStyle(color: Colors.white54)),
        ),
      ]),
    );
  }
}
