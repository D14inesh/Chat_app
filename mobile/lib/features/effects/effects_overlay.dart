/// Message effects — "Happy birthday" brings balloons and confetti,
/// "Congratulations" confetti, "Love you" hearts. Plays once when the
/// message is sent or arrives live (same words as the website). Can be
/// switched off in Chat features.
library effects_overlay;

import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/prefs_store.dart';

enum ChatEffect { confetti, birthday, hearts }

final _rules = <(RegExp, ChatEffect)>[
  (RegExp(r'\b(happy\s*b(irth)?day|hbd)\b|🎂|🎈', caseSensitive: false), ChatEffect.birthday),
  (RegExp(r'\bhappy\s*new\s*year\b|🎆|🎇', caseSensitive: false), ChatEffect.confetti),
  (RegExp(r'\b(congrat(s|ulations)?|well done|great job|proud of you)\b|🎉|🥳|🎊', caseSensitive: false), ChatEffect.confetti),
  (RegExp(r'\b(i\s*)?love\s*(you|u)\b|\bmiss\s*(you|u)\b|❤️|😍|🥰|💕|💖', caseSensitive: false), ChatEffect.hearts),
];

ChatEffect? effectFor(String? text) {
  if (text == null) return null;
  for (final (re, effect) in _rules) {
    if (re.hasMatch(text)) return effect;
  }
  return null;
}

/// Set this to play an effect; the overlay at the app root picks it up.
final effectTrigger = ValueNotifier<ChatEffect?>(null);

void maybePlayEffect(String? text) {
  if (!PrefsStore.instance.effects) return;
  final e = effectFor(text);
  if (e != null) {
    effectTrigger.value = null;
    effectTrigger.value = e;
  }
}

class EffectsOverlay extends StatefulWidget {
  const EffectsOverlay({super.key});
  @override
  State<EffectsOverlay> createState() => _EffectsOverlayState();
}

class _Particle {
  final String kind; // confetti | balloon | heart
  double x, y, vx, vy, rot, vr, size, sway;
  final Color color;
  _Particle(this.kind, this.x, this.y, this.vx, this.vy, this.rot, this.vr, this.size, this.sway, this.color);
}

class _EffectsOverlayState extends State<EffectsOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
    ..addListener(_tick)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _parts = []);
    });
  List<_Particle> _parts = [];
  final _rnd = Random();
  Duration _last = Duration.zero;

  static const _colors = [Color(0xFFFF6B6B), Color(0xFFFDCB6E), Color(0xFF2EE6A6), Color(0xFF6FA1FF), Color(0xFFE84393), Color(0xFFA29BFE), Color(0xFF00C2FF)];

  @override
  void initState() {
    super.initState();
    effectTrigger.addListener(_start);
  }

  @override
  void dispose() {
    effectTrigger.removeListener(_start);
    _ctrl.dispose();
    super.dispose();
  }

  double _r(double a, double b) => a + _rnd.nextDouble() * (b - a);

  void _start() {
    final effect = effectTrigger.value;
    if (effect == null || _ctrl.isAnimating) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return;
    final size = MediaQuery.of(context).size;
    final w = size.width, h = size.height;
    final parts = <_Particle>[];
    if (effect == ChatEffect.confetti || effect == ChatEffect.birthday) {
      for (var i = 0; i < 120; i++) {
        parts.add(_Particle('confetti', _r(0, w), _r(-h * 0.6, -10), _r(-1.5, 1.5), _r(2, 5.5), _r(0, pi), _r(-0.2, 0.2), _r(6, 11), 0, _colors[i % _colors.length]));
      }
    }
    if (effect == ChatEffect.birthday) {
      for (var i = 0; i < 10; i++) {
        parts.add(_Particle('balloon', _r(30, w - 30), h + _r(20, 300), 0, -_r(1.6, 3), 0, 0, _r(18, 28), _r(0, 6), _colors[i % _colors.length]));
      }
    }
    if (effect == ChatEffect.hearts) {
      for (var i = 0; i < 32; i++) {
        parts.add(_Particle('heart', _r(0, w), h + _r(10, 400), _r(-0.5, 0.5), -_r(1.5, 3.8), 0, 0, _r(14, 32), _r(0, 6),
            const [Color(0xFFFF6B81), Color(0xFFE84393), Color(0xFFFF8FA3)][i % 3]));
      }
    }
    setState(() => _parts = parts);
    _last = Duration.zero;
    _ctrl.forward(from: 0);
  }

  void _tick() {
    final now = _ctrl.lastElapsedDuration ?? Duration.zero;
    final dt = ((now - _last).inMicroseconds / 16667).clamp(0.0, 3.0); // in 60fps frames
    _last = now;
    final t = now.inMilliseconds / 1000;
    for (final p in _parts) {
      p.x += (p.vx + (p.sway != 0 ? sin(t * 2.5 + p.sway) * 0.6 : 0)) * dt;
      p.y += p.vy * dt;
      p.rot += p.vr * dt;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_parts.isEmpty) return const SizedBox.shrink();
    final fade = _ctrl.value > 0.82 ? (1 - _ctrl.value) / 0.18 : 1.0;
    return IgnorePointer(
      child: Opacity(opacity: fade.clamp(0.0, 1.0), child: CustomPaint(size: Size.infinite, painter: _EffectsPainter(_parts, _ctrl.value))),
    );
  }
}

class _EffectsPainter extends CustomPainter {
  final List<_Particle> parts;
  final double progress;
  _EffectsPainter(this.parts, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in parts) {
      paint.color = p.color;
      if (p.kind == 'confetti') {
        canvas.save();
        canvas.translate(p.x, p.y);
        canvas.rotate(p.rot);
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 1.4 * cos(p.rot * 2).abs()), paint);
        canvas.restore();
      } else if (p.kind == 'balloon') {
        final string = Paint()
          ..color = Colors.white54
          ..strokeWidth = 1;
        canvas.drawLine(Offset(p.x, p.y + p.size), Offset(p.x + sin(progress * 20) * 4, p.y + p.size + 40), string);
        canvas.drawOval(Rect.fromCenter(center: Offset(p.x, p.y), width: p.size * 1.7, height: p.size * 2), paint);
        canvas.drawOval(
          Rect.fromCenter(center: Offset(p.x - p.size * 0.3, p.y - p.size * 0.35), width: p.size * 0.36, height: p.size * 0.6),
          Paint()..color = Colors.white38,
        );
      } else {
        final s = p.size;
        final path = Path()
          ..moveTo(p.x, p.y + s * 0.3)
          ..cubicTo(p.x, p.y, p.x - s / 2, p.y, p.x - s / 2, p.y + s * 0.3)
          ..cubicTo(p.x - s / 2, p.y + s * 0.6, p.x, p.y + s * 0.8, p.x, p.y + s)
          ..cubicTo(p.x, p.y + s * 0.8, p.x + s / 2, p.y + s * 0.6, p.x + s / 2, p.y + s * 0.3)
          ..cubicTo(p.x + s / 2, p.y, p.x, p.y, p.x, p.y + s * 0.3);
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EffectsPainter old) => true;
}
