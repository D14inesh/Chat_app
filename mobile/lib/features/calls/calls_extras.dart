/// Call history (with the missed-call badge) and ringtones — the phone side
/// of the website's js/features/calls.js. Ringtones are generated here as
/// short WAV clips (same note patterns as the website), so no sound files
/// ship with the app; one can be chosen per contact.
library calls_extras;

import '../../theme.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/avatar.dart';
import '../../core/prefs_store.dart';
import '../auth/session.dart';
import '../conversations/conversations_provider.dart';
import '../groups/group_tools.dart';
import 'call_controller.dart';
import 'group_call_screen.dart';

// ── Ringtones ───────────────────────────────────────────────

class Ringtone {
  final String name;
  final double every; // seconds per repeat
  final List<(double freq, double at, double len)> notes;
  final String wave; // sine | triangle | square
  const Ringtone(this.name, this.every, this.notes, {this.wave = 'triangle'});
}

const kRingtones = <String, Ringtone>{
  'classic': Ringtone('Classic ring', 3, [(480, 0, 0.4), (620, 0, 0.4), (480, 0.5, 0.4), (620, 0.5, 0.4)]),
  'chime': Ringtone('Chime', 2.6, [(1046.5, 0, 0.35), (1318.5, 0.18, 0.35), (1568, 0.36, 0.6)]),
  'marimba': Ringtone('Marimba', 2.2, [(523.25, 0, 0.18), (659.25, 0.15, 0.18), (783.99, 0.3, 0.18), (659.25, 0.45, 0.18), (1046.5, 0.6, 0.3)]),
  'pulse': Ringtone('Pulse', 1.6, [(880, 0, 0.12), (880, 0.2, 0.12), (880, 0.4, 0.12)]),
  'retro': Ringtone('Retro', 2.4, [(1200, 0, 0.08), (900, 0.1, 0.08), (1200, 0.2, 0.08), (900, 0.3, 0.08), (1200, 0.4, 0.08), (900, 0.5, 0.08)],
      wave: 'square'),
  'calm': Ringtone('Calm', 4, [(392, 0, 1.2), (523.25, 0.6, 1.2), (659.25, 1.2, 1.6)], wave: 'sine'),
  'silent': Ringtone('Silent', 10, []),
};

String defaultRingtone() {
  final v = PrefsStore.instance.get('ringtone.default') as String?;
  return kRingtones.containsKey(v) ? v! : 'classic';
}

String? ringtoneOverride(String userId) {
  final v = PrefsStore.instance.get('ringtone.$userId') as String?;
  return kRingtones.containsKey(v) ? v : null;
}

String ringtoneFor(String userId) => ringtoneOverride(userId) ?? defaultRingtone();

/// One repeat of a tone as a 16-bit mono WAV (silence pads it to `every`).
Uint8List ringtoneWav(String id, {double volume = 0.35}) {
  final tone = id == 'ringback'
      ? const Ringtone('Ring-back', 3, [(480, 0, 0.4), (620, 0, 0.4)], wave: 'sine')
      : (kRingtones[id] ?? kRingtones['classic']!);
  const rate = 22050;
  final n = (tone.every * rate).round();
  final samples = Float64List(n);
  for (final (freq, at, len) in tone.notes) {
    final start = (at * rate).round();
    final count = (len * rate).round();
    for (var i = 0; i < count && start + i < n; i++) {
      final t = i / rate;
      final phase = 2 * math.pi * freq * t;
      final raw = switch (tone.wave) {
        'square' => math.sin(phase) >= 0 ? 1.0 : -1.0,
        'sine' => math.sin(phase),
        _ => 2 / math.pi * math.asin(math.sin(phase)),
      };
      final env = math.min(1.0, t / 0.02) * math.exp(-3.2 * t / len);
      samples[start + i] += raw * env;
    }
  }
  final v = id == 'ringback' ? volume * 0.4 : volume;
  final data = ByteData(44 + n * 2);
  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * v * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Plays a ringtone on a loop while a call rings.
class Ringer {
  Ringer._();
  static final instance = Ringer._();
  final _player = AudioPlayer();
  String? _playing;

  Future<void> start(String id) async {
    if (_playing == id) return;
    await stop();
    if (id == 'silent') return;
    _playing = id;
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(BytesSource(ringtoneWav(id)));
    if (id != 'ringback') HapticFeedback.heavyImpact();
  }

  Future<void> preview(String id) async {
    await stop();
    if (id == 'silent') return;
    await _player.setReleaseMode(ReleaseMode.release);
    await _player.play(BytesSource(ringtoneWav(id)));
  }

  Future<void> stop() async {
    _playing = null;
    await _player.stop();
  }
}

/// Rings for incoming calls (the caller's ringtone) and plays a soft
/// ring-back while my own call rings — mounted once at the app root.
class CallRinger extends ConsumerWidget {
  const CallRinger({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(callControllerProvider.select((s) => (s.phase, s.peerUserId)), (_, next) {
      final (phase, peer) = next;
      if (phase == CallPhase.incomingRinging && peer != null) {
        Ringer.instance.start(ringtoneFor(peer));
      } else if (phase == CallPhase.outgoingRinging) {
        Ringer.instance.start('ringback');
      } else {
        Ringer.instance.stop();
      }
    });
    return const SizedBox.shrink();
  }
}

/// Pick a ringtone: for a contact (userId) or the default.
Future<void> showRingtonePicker(BuildContext context, {String? userId, String? name}) async {
  final current = userId == null ? defaultRingtone() : (ringtoneOverride(userId) ?? '');
  var picked = current;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(userId == null ? 'Default ringtone' : 'Ringtone for $name', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(userId == null ? 'For incoming calls, unless a contact has their own.' : 'Plays when they call you.',
              style: const TextStyle(color: VeyonColors.muted)),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              if (userId != null)
                ListTile(
                  leading: _radio(ctx, picked == ''),
                  onTap: () => set(() => picked = ''),
                  title: Text('Default (${kRingtones[defaultRingtone()]!.name})'),
                ),
              for (final e in kRingtones.entries)
                ListTile(
                  leading: _radio(ctx, picked == e.key),
                  onTap: () {
                    set(() => picked = e.key);
                    Ringer.instance.preview(e.key);
                  },
                  title: Text(e.value.name),
                  trailing: e.key == 'silent'
                      ? null
                      : IconButton(icon: const Icon(Icons.play_arrow_rounded), onPressed: () => Ringer.instance.preview(e.key)),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ]),
          ),
        ]),
      ),
    ),
  );
  await Ringer.instance.stop();
  if (ok != true) return;
  if (userId == null) {
    PrefsStore.instance.put('ringtone.default', picked.isEmpty ? 'classic' : picked);
  } else {
    PrefsStore.instance.put('ringtone.$userId', picked);
  }
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ringtone saved.')));
}

Widget _radio(BuildContext context, bool on) => Icon(
      on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
      color: on ? Theme.of(context).colorScheme.secondary : VeyonColors.muted,
    );

// ── Call history ────────────────────────────────────────────

final missedCallsProvider = StateProvider<int>((ref) => 0);

Future<void> refreshMissedCalls(WidgetRef ref) async {
  try {
    final r = await ref.read(sessionControllerProvider).api.getJson('/api/calls/missed');
    ref.read(missedCallsProvider.notifier).state = (r['missed'] as num?)?.toInt() ?? 0;
  } catch (_) {}
}

/// Keeps the badge current: a "call-log" frame arrives whenever a call ends.
class MissedCallsWatcher extends ConsumerStatefulWidget {
  const MissedCallsWatcher({super.key});
  @override
  ConsumerState<MissedCallsWatcher> createState() => _MissedCallsWatcherState();
}

class _MissedCallsWatcherState extends ConsumerState<MissedCallsWatcher> {
  StreamSubscription<Map<String, dynamic>>? _sub;

  void _listen() {
    _sub?.cancel();
    _sub = ref.read(sessionControllerProvider).ws?.frames.listen((f) {
      if (f['type'] == 'call-log' || f['type'] == 'connected') refreshMissedCalls(ref);
    });
  }

  @override
  void initState() {
    super.initState();
    _listen();
    refreshMissedCalls(ref);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionControllerProvider.select((s) => s.ws), (_, __) => _listen());
    return const SizedBox.shrink();
  }
}

String _duration(int? s) {
  if (s == null) return '';
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  return m < 60 ? '$m:${(s % 60).toString().padLeft(2, '0')}' : '${m ~/ 60} h ${m % 60} min';
}

String _when(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final now = DateTime.now();
  final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today $hm';
  final y = now.subtract(const Duration(days: 1));
  if (d.year == y.year && d.month == y.month && d.day == y.day) return 'Yesterday $hm';
  return '${d.day}/${d.month} $hm';
}

class CallsScreen extends ConsumerStatefulWidget {
  const CallsScreen({super.key});
  @override
  ConsumerState<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends ConsumerState<CallsScreen> {
  List<Map<String, dynamic>>? _calls;
  String? _error;
  bool _missedOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(sessionControllerProvider).api;
    try {
      final r = await api.getJson('/api/calls');
      if (!mounted) return;
      setState(() => _calls = (r['calls'] as List).cast<Map<String, dynamic>>());
      await api.postJson('/api/calls/seen');
      ref.read(missedCallsProvider.notifier).state = 0;
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load your calls — check your connection.');
    }
  }

  Future<void> _callBack(Map<String, dynamic> c, String type) async {
    final conv = ref.read(conversationsProvider.notifier).byId(c['conversationId'] as String);
    if (conv == null) return;
    if (c['isGroup'] == true) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupCallScreen(conversation: conv, callType: type)));
    } else {
      final peer = conv.peer;
      if (peer == null) return;
      await ref.read(callControllerProvider.notifier).startCall(
            conversationId: conv.id, peerUserId: peer.id, peerName: peer.displayName, callType: type);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    final all = _calls;
    final shown = all == null
        ? null
        : _missedOnly
            ? all.where((c) => c['status'] == 'missed' && c['direction'] == 'incoming').toList()
            : all;
    return Scaffold(
      appBar: AppBar(title: const Text('Calls'), actions: [
        IconButton(tooltip: 'Ringtone', icon: const Icon(Icons.music_note_rounded), onPressed: () => showRingtonePicker(context)),
        PopupMenuButton<String>(
          onSelected: (_) async {
            await ref.read(sessionControllerProvider).api.deleteJson('/api/calls').catchError((_) => <String, dynamic>{});
            _load();
          },
          itemBuilder: (_) => const [PopupMenuItem(value: 'clear', child: Text('Clear call history'))],
        ),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            ChoiceChip(label: const Text('All'), selected: !_missedOnly, onSelected: (_) => setState(() => _missedOnly = false)),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text('Missed'), selected: _missedOnly, onSelected: (_) => setState(() => _missedOnly = true)),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(children: [
              if (_error != null) Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
              if (shown == null && _error == null) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
              if (shown != null && shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 80),
                  child: Column(children: [
                    Icon(Icons.call_rounded, size: 56, color: accent.withValues(alpha: 0.5)),
                    const SizedBox(height: 10),
                    Text(_missedOnly ? 'No missed calls.' : 'No calls yet.', style: const TextStyle(color: VeyonColors.muted)),
                  ]),
                ),
              for (final c in shown ?? const <Map<String, dynamic>>[]) _row(c),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> c) {
    final incoming = c['direction'] == 'incoming';
    final status = c['status'] as String;
    final bad = status == 'missed' || status == 'declined';
    final missed = status == 'missed' && incoming;
    final peer = c['peer'] as Map<String, dynamic>?;
    final what = c['isGroup'] == true
        ? 'Group call'
        : status == 'missed'
            ? (incoming ? 'Missed' : 'No answer')
            : status == 'declined'
                ? (incoming ? 'Declined' : 'Declined by them')
                : incoming
                    ? 'Incoming'
                    : 'Outgoing';
    final dur = _duration((c['duration'] as num?)?.toInt());
    return ListTile(
      leading: Avatar(label: c['title'] as String? ?? '?', color: c['avatarColor'] as String?, photoUrl: peer?['photoUrl'] as String?),
      title: Text(c['title'] as String? ?? 'Unknown',
          style: TextStyle(color: missed ? const Color(0xFFFF6B6B) : null, fontWeight: FontWeight.w600)),
      subtitle: Row(children: [
        Icon(incoming ? Icons.call_received_rounded : Icons.call_made_rounded, size: 15, color: bad ? const Color(0xFFFF6B6B) : const Color(0xFF2EE6A6)),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '$what${c['callType'] == 'video' ? ' · video' : ''} · ${_when(c['startedAt'] as String)}${dur.isNotEmpty ? ' · $dur' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: VeyonColors.muted),
          ),
        ),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.call_rounded), onPressed: () => _callBack(c, 'audio')),
        IconButton(icon: const Icon(Icons.videocam_rounded), onPressed: () => _callBack(c, 'video')),
      ]),
      onTap: () => openChatById(context, ref, c['conversationId'] as String),
    );
  }
}
