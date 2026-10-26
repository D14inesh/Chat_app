/// One voice-message player for the whole app (the website does the same):
/// it keeps playing while you scroll or leave the chat, has a speed control
/// (1× / 1.5× / 2×, remembered) and a mini-player bar at the bottom.
library voice_playback;

import '../../theme.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/prefs_store.dart';

const kVoiceSpeeds = [1.0, 1.5, 2.0];

class VoicePlayback extends ChangeNotifier {
  final _player = AudioPlayer();
  String? currentId;
  String title = '';
  bool playing = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double speed = PrefsStore.instance.voiceSpeed;

  VoicePlayback() {
    _player.onPositionChanged.listen((p) {
      position = p;
      notifyListeners();
    });
    _player.onDurationChanged.listen((d) {
      duration = d;
      notifyListeners();
    });
    _player.onPlayerStateChanged.listen((s) {
      playing = s == PlayerState.playing;
      notifyListeners();
    });
    _player.onPlayerComplete.listen((_) => stop());
  }

  String get speedLabel => '${speed == speed.roundToDouble() ? speed.toInt() : speed}×';

  bool isPlaying(String id) => currentId == id && playing;

  Future<void> toggle({required String id, required String title, required Future<Uint8List?> Function() bytes}) async {
    if (currentId == id) {
      playing ? await _player.pause() : await _player.resume();
      return;
    }
    final data = await bytes();
    if (data == null) return;
    await _player.stop();
    currentId = id;
    this.title = title;
    position = Duration.zero;
    duration = Duration.zero;
    await _player.play(BytesSource(data));
    await _player.setPlaybackRate(speed);
    notifyListeners();
  }

  Future<void> cycleSpeed() async {
    speed = kVoiceSpeeds[(kVoiceSpeeds.indexOf(speed) + 1) % kVoiceSpeeds.length];
    PrefsStore.instance.voiceSpeed = speed;
    if (currentId != null) await _player.setPlaybackRate(speed);
    notifyListeners();
  }

  Future<void> seekFraction(double f) async {
    if (duration > Duration.zero) await _player.seek(duration * f.clamp(0, 1));
  }

  Future<void> stop() async {
    await _player.stop();
    currentId = null;
    playing = false;
    position = Duration.zero;
    notifyListeners();
  }
}

final voicePlaybackProvider = ChangeNotifierProvider<VoicePlayback>((ref) => VoicePlayback());

String fmtVoice(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Mounted at the app root, above every screen.
class VoiceMiniPlayer extends ConsumerWidget {
  const VoiceMiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vp = ref.watch(voicePlaybackProvider);
    final accent = Theme.of(context).colorScheme.secondary;
    final show = vp.currentId != null;
    final progress = vp.duration.inMilliseconds == 0 ? 0.0 : vp.position.inMilliseconds / vp.duration.inMilliseconds;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      left: 10,
      right: 10,
      bottom: show ? 86 : -120,
      child: SafeArea(
        top: false,
        child: !show
            ? const SizedBox.shrink()
            : Material(
                color: Theme.of(context).colorScheme.surface,
                elevation: 10,
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
                  child: Row(children: [
                    IconButton.filled(
                      style: IconButton.styleFrom(backgroundColor: accent),
                      icon: Icon(vp.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                      onPressed: () => vp.toggle(id: vp.currentId!, title: vp.title, bytes: () async => null),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(vp.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                        const SizedBox(height: 6),
                        LayoutBuilder(
                          builder: (ctx, c) => GestureDetector(
                            onTapDown: (d) => vp.seekFraction(d.localPosition.dx / c.maxWidth),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(value: progress, minHeight: 4, color: accent, backgroundColor: VeyonColors.hairline),
                            ),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    Text(fmtVoice(vp.position), style: const TextStyle(color: VeyonColors.muted, fontSize: 11.5)),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: vp.cycleSpeed,
                      style: TextButton.styleFrom(minimumSize: const Size(44, 32), visualDensity: VisualDensity.compact),
                      child: Text(vp.speedLabel, style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                    IconButton(icon: const Icon(Icons.close_rounded, size: 20), onPressed: vp.stop),
                  ]),
                ),
              ),
      ),
    );
  }
}
