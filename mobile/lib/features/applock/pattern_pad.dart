/// 3×3 pattern grid — drag across dots to draw a pattern (the website's
/// createPatternGrid). Reports the dot sequence (0–8) when the finger lifts.
library pattern_pad;

import 'package:flutter/material.dart';

import '../../theme.dart';

class PatternPad extends StatefulWidget {
  final ValueChanged<List<int>> onComplete;
  final double size;
  const PatternPad({super.key, required this.onComplete, this.size = 260});

  @override
  State<PatternPad> createState() => _PatternPadState();
}

class _PatternPadState extends State<PatternPad> {
  final List<int> _seq = [];
  Offset? _finger;

  Offset _center(int i) {
    final cell = widget.size / 3;
    return Offset((i % 3) * cell + cell / 2, (i ~/ 3) * cell + cell / 2);
  }

  void _hit(Offset p) {
    final cell = widget.size / 3;
    for (var i = 0; i < 9; i++) {
      if ((p - _center(i)).distance < cell * 0.32 && !_seq.contains(i)) {
        setState(() => _seq.add(i));
      }
    }
    setState(() => _finger = p);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) {
        setState(_seq.clear);
        _hit(d.localPosition);
      },
      onPanUpdate: (d) => _hit(d.localPosition),
      onPanEnd: (_) {
        final seq = List<int>.from(_seq);
        setState(() {
          _finger = null;
          _seq.clear();
        });
        if (seq.isNotEmpty) widget.onComplete(seq);
      },
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(painter: _PatternPainter(_seq, _finger, _center)),
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  final List<int> seq;
  final Offset? finger;
  final Offset Function(int) center;
  _PatternPainter(this.seq, this.finger, this.center);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = VeyonColors.bubbleMe2
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < seq.length; i++) {
      canvas.drawLine(center(seq[i - 1]), center(seq[i]), line);
    }
    if (finger != null && seq.isNotEmpty) canvas.drawLine(center(seq.last), finger!, line);
    for (var i = 0; i < 9; i++) {
      final on = seq.contains(i);
      canvas.drawCircle(center(i), on ? 14 : 9, Paint()..color = on ? VeyonColors.bubbleMe2 : Colors.white38);
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPainter old) => true;
}
