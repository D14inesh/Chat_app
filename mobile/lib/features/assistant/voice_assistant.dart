/// "Hey ARM" voice commands — the website's wake-word assistant. Once
/// turned on it keeps listening; after "hey arm" it understands:
///   · "call <name>" / "video call <name>"
///   · "say <text> to <name>" / "send <text> to <name>"
///   · "tell <name> <text>" / "message <name> <text>"
///   · "open chat with <name>"
/// Plain pattern matching (no AI), same patterns and wording as the website.
/// Android's recogniser works in short sessions, so it's restarted after each
/// one — some phones play their "listening" beep each time.
library voice_assistant;

import 'package:veyon_chat_mobile/features/account/birth_date.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/keys.dart';
import '../../core/key_resolver.dart';
import '../../core/nav_key.dart';
import '../../models/conversation.dart';
import '../auth/session.dart';
import '../calls/call_controller.dart';
import '../chat/chat_screen.dart';
import '../conversations/conversations_provider.dart';

// Same loose wake match as the website: survives common mishearings of
// "hey arm", and a bare "he"/"hey"/"hi" right before a command word
// ("he say hello to manju") — engines often drop the "arm" entirely.
const _hey = "(?:hey|hay|hei|he|hi|hii|ok|okay|a)";
const _arm = "(?:arm|arms|aarm|harm|ram|alarm|army|am|aam|aum|umm?|uhm|ahm|erm|i'?m|on|ah|art|arn|alm|ma'?am)";
const _verbs = "(?:call|video|say|send|tell|message|msg|open|start|make|please|text)";
final _wakeRe = RegExp('\\b(?:$_hey\\s+$_arm|harm|hey\\s*arm|(?:hey|hay|hei|he|hi|hii)(?=\\s+$_verbs\\b))\\b');

/// Drops filler between the wake phrase and the command ("can you please …").
String _cleanCommand(String text) => text
    .trim()
    .replaceFirst(RegExp(r'^(?:arm|um+|uh|so|and|ok|okay)\s+'), '')
    .replaceFirst(RegExp(r'^(?:can you|could you|will you|would you|please|kindly)\s+'), '')
    .replaceFirst(RegExp(r'^please\s+'), '')
    .trim();

/// A rough "sounds like" spelling, so how a speech engine writes an Indian
/// name ("manjoo", "preeti", "abhi") lines up with how it's saved
/// ("Manju", "Priti", "Abi"). Same rules as the website.
String _soundKey(String name) => name
    .toLowerCase()
    .replaceAll(RegExp('[^a-z]'), '')
    .replaceAll(RegExp('oo|ou'), 'u')
    .replaceAll(RegExp('ee|ea|ie'), 'i')
    .replaceAll('aa', 'a')
    .replaceAll(RegExp('(?<=[kgcjtdpb])h'), '')
    .replaceAll('ph', 'f')
    .replaceAll('w', 'v')
    .replaceAll('z', 's')
    .replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);

int _editDistance(String a, String b) {
  final row = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    var prev = row[0];
    row[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final tmp = row[j];
      row[j] = [row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce((x, y) => x < y ? x : y);
      prev = tmp;
    }
  }
  return row[b.length];
}

class VoiceAssistantState {
  final bool active;
  final String badge; // what the floating badge says
  const VoiceAssistantState({this.active = false, this.badge = ''});
}

class VoiceAssistant extends StateNotifier<VoiceAssistantState> {
  final Ref _ref;
  final _speech = SpeechToText();
  bool _ready = false;
  Timer? _silence;
  String _lastCommand = '';

  VoiceAssistant(this._ref) : super(const VoiceAssistantState()) {
    _restorePreference();
  }

  Future<File> _prefFile() async => File('${(await getApplicationSupportDirectory()).path}/voice_commands_on');

  Future<void> _restorePreference() async {
    // On unless turned off by hand (the file then says "off"), like the website.
    try {
      final f = await _prefFile();
      if (await f.exists() && (await f.readAsString()).trim() == 'off') return;
    } catch (_) {}
    start(quiet: true);
  }

  Future<void> toggle() => state.active ? stop() : start();

  Future<void> start({bool quiet = false}) async {
    _ready = _ready ||
        await _speech.initialize(
          onStatus: _onStatus,
          onError: _onError,
        );
    if (!_ready) {
      if (!quiet) _toast('Voice commands need speech recognition and microphone access on this phone.');
      return;
    }
    state = const VoiceAssistantState(active: true);
    try {
      await (await _prefFile()).writeAsString('on');
    } catch (_) {}
    if (!quiet) _toast('Voice commands on — say "Hey ARM, call Manju".');
    _listen();
  }

  Future<void> stop({bool remember = true}) async {
    state = const VoiceAssistantState();
    _silence?.cancel();
    await _speech.cancel();
    if (!remember) return;
    try {
      await (await _prefFile()).writeAsString('off');
    } catch (_) {}
  }

  void _listen() {
    if (!state.active || _speech.isListening) return;
    // The microphone belongs to the call while one is going — try again later.
    if (_ref.read(callControllerProvider).isActive) {
      Future.delayed(const Duration(seconds: 5), _listen);
      return;
    }
    _speech.listen(
      onResult: (r) => _onTranscript(r.recognizedWords),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        // Indian English hears Indian names and accents far better.
        localeId: 'en_IN',
        cancelOnError: false,
        listenFor: const Duration(minutes: 1),
        pauseFor: const Duration(seconds: 4),
      ),
    );
  }

  void _onStatus(String status) {
    // A session ended (silence / time limit) — start the next one.
    if ((status == 'done' || status == 'notListening') && state.active) {
      Future.delayed(const Duration(milliseconds: 400), _listen);
    }
  }

  void _onError(SpeechRecognitionError e) {
    if (e.errorMsg.contains('permission')) {
      _toast('Voice commands need microphone access — allow it in the app\'s permissions, then turn them on from ⋮.');
      stop(remember: false);
    }
  }

  void _onTranscript(String raw) {
    final t = raw.toLowerCase().replaceAll(RegExp(r'[.,!?]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final m = _wakeRe.firstMatch(t);
    if (m == null) {
      // Ordinary talk near the phone — not for us; stay quiet.
      if (state.badge.isNotEmpty) state = const VoiceAssistantState(active: true);
      return;
    }
    final command = _cleanCommand(t.substring(m.end));
    state = VoiceAssistantState(active: true, badge: command.isEmpty ? 'Listening — go ahead…' : '"$command"');
    // A command is done once speech pauses for a moment.
    _silence?.cancel();
    _silence = Timer(const Duration(milliseconds: 1800), () async {
      if (command.isEmpty || command == _lastCommand) return;
      _lastCommand = command;
      await _speech.stop(); // fresh transcript for the next "hey arm"
      await _execute(command);
      Future.delayed(const Duration(seconds: 2), () => _lastCommand = '');
      if (state.active) state = const VoiceAssistantState(active: true);
    });
  }

  Future<void> _execute(String command) async {
    final text = command.replaceAll(RegExp(r'[.,!?]+$'), '');
    RegExpMatch? m;

    m = RegExp(r'^(?:please\s+)?(?:make a |start a )?(video\s*)?call(?:\s+to)?\s+(.+)$', caseSensitive: false).firstMatch(text);
    if (m != null) return _call(m.group(2)!, m.group(1) != null ? 'video' : 'audio');

    m = RegExp(r'^(?:please\s+)?say\s+(.+?)\s+to\s+(.+)$', caseSensitive: false).firstMatch(text);
    if (m != null) return _send(m.group(2)!, m.group(1)!);

    m = RegExp(r'^(?:please\s+)?send\s+(.+?)\s+to\s+(.+)$', caseSensitive: false).firstMatch(text);
    if (m != null) return _send(m.group(2)!, m.group(1)!);

    m = RegExp(r'^(?:please\s+)?(?:tell|message)\s+(.+?)\s+(?:that\s+|to\s+say\s+)?(.+)$', caseSensitive: false).firstMatch(text);
    if (m != null) return _send(m.group(1)!, m.group(2)!);

    m = RegExp(r'^(?:please\s+)?open(?:\s+(?:the\s+)?chat)?(?:\s+with)?\s+(.+)$', caseSensitive: false).firstMatch(text);
    if (m != null) return _open(m.group(1)!);

    _toast('Heard "$command" — didn\'t recognize that as a command.');
  }

  /// Exact name first, then "starts with", then "contains", then close
  /// spellings ("manjoo" → Manju) — names come back from speech spelled
  /// every which way.
  Conversation? _find(String name) {
    final target = name.toLowerCase().trim().replaceAll(RegExp(r'[.,!?]+$'), '').replaceFirst(RegExp(r'^(?:to|with)\s+'), '');
    if (target.isEmpty) return null;
    final direct = (_ref.read(conversationsProvider).valueOrNull ?? const <Conversation>[])
        .where((c) => !c.isGroup && c.peer != null)
        .toList();
    List<String> names(Conversation c) => [c.peer!.displayName, c.peer!.username].map((n) => n.toLowerCase()).toList();
    final hit = direct.where((c) => names(c).contains(target)).firstOrNull ??
        direct.where((c) => names(c).any((n) => n.startsWith(target) || n.split(' ').first == target)).firstOrNull ??
        direct.where((c) => names(c).any((n) => n.contains(target))).firstOrNull;
    if (hit != null) return hit;
    // Compare by sound, allowing about one wrong letter in three.
    final spoken = _soundKey(target);
    Conversation? best;
    var bestScore = 1 << 30;
    for (final c in direct) {
      for (final n in names(c).expand((n) => [n, n.split(' ').first])) {
        final key = _soundKey(n);
        final d = _editDistance(spoken, key);
        final allowed = (key.length / 3).round() < 1 ? 1 : (key.length / 3).round();
        if (d <= allowed && d < bestScore) {
          best = c;
          bestScore = d;
        }
      }
    }
    return best;
  }

  void _openChat(Conversation c) {
    veyonNavigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => ChatScreen(conversation: c)));
  }

  Future<void> _call(String name, String type) async {
    if (!await privateChatGate()) return; // private chats are 18+
    final c = _find(name);
    if (c == null) return _toast('Couldn\'t find a contact named "${name.trim()}".');
    _openChat(c);
    _toast('${type == 'video' ? 'Video calling' : 'Calling'} ${c.peer!.displayName}…');
    await _ref.read(callControllerProvider.notifier).startCall(
          conversationId: c.id,
          peerUserId: c.peer!.id,
          peerName: c.peer!.displayName,
          callType: type,
        );
  }

  Future<void> _send(String name, String text) async {
    if (!await privateChatGate()) return; // private chats are 18+
    final c = _find(name);
    if (c == null) return _toast('Couldn\'t find a contact named "${name.trim()}".');
    final session = _ref.read(sessionControllerProvider);
    try {
      final key = await resolveConversationKey(session, c);
      final env = await encryptText(key, text.trim());
      session.ws?.sendMessage(conversationId: c.id, ciphertext: env.ciphertext, iv: env.iv, tempId: const Uuid().v4());
      _openChat(c);
      _toast('Sent to ${c.peer!.displayName}: "${text.trim()}"');
    } catch (_) {
      _toast('Could not send that message.');
    }
  }

  void _open(String name) {
    final c = _find(name);
    if (c == null) return _toast('Couldn\'t find a contact named "${name.trim()}".');
    _openChat(c);
    _toast('Opened chat with ${c.peer!.displayName}.');
  }

  void _toast(String text) {
    final ctx = veyonNavigatorKey.currentContext;
    if (ctx != null) ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _silence?.cancel();
    _speech.cancel();
    super.dispose();
  }
}

final voiceAssistantProvider = StateNotifierProvider<VoiceAssistant, VoiceAssistantState>((ref) => VoiceAssistant(ref));

/// The small floating "🎙️ listening…" badge, shown while voice commands are on.
class VoiceAssistantBadge extends ConsumerWidget {
  const VoiceAssistantBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(voiceAssistantProvider);
    // Only while a command is being heard — no banner while just waiting.
    if (!s.active || s.badge.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 12,
      bottom: 90,
      child: SafeArea(
        child: GestureDetector(
          onTap: () => ref.read(voiceAssistantProvider.notifier).stop(),
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width - 48),
                child: Text('🎙️ ${s.badge}', overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
