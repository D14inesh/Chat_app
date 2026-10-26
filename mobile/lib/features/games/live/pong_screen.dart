import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme.dart';
import 'live_game_controller.dart';

/// Live 1:1 Pong -- exact port of the website's (app.js startPongGame and
/// friends) so phone and browser players can play each other.
///
/// Host-authoritative: only the host (the inviter) runs the ball physics and
/// broadcasts `{type:'pong-state', state:{ballX, ballY, hostY, hostScore,
/// guestScore}}` ~20×/s; the guest only sends `{type:'pong-paddle', y}` and
/// smooths the ball between updates. Host starts with `{type:'pong-init',
/// startAt}` and finishes with end `{winner, hostScore, guestScore}`.
///
/// Coordinates are height-normalized: y is 0..1 of the court height, x is
/// 0..16/9. Host paddle on the left, guest paddle on the right; drag up and
/// down to move yours.
class PongScreen extends ConsumerStatefulWidget {
  final bool isHost;
  const PongScreen({super.key, required this.isHost});

  static Route<void> route({required bool isHost}) => MaterialPageRoute(builder: (_) => PongScreen(isHost: isHost));

  @override
  ConsumerState<PongScreen> createState() => _PongScreenState();
}

const _aspect = 16 / 9;
const _winScore = 7;
const _paddleHalfH = 0.11;
const _paddleHalfW = 0.018;
const _paddleXInset = 0.09;
const _ballR = 0.02;
const _baseSpeed = 1.0; // court-heights per second
const _speedUp = 1.05; // per paddle hit
const _maxSpeed = 2.4;
const _broadcastMs = 50;
const _serveDelayMs = 900;

class _PongScreenState extends ConsumerState<PongScreen> with SingleTickerProviderStateMixin {
  late final String _peerName;
  late final LiveGameController _game;
  late final Ticker _ticker;
  StreamSubscription<Map<String, dynamic>>? _moveSub;
  StreamSubscription<Map<String, dynamic>>? _endSub;
  final _rnd = Random();

  double _myY = 0.5, _peerY = 0.5;
  double _ballX = _aspect / 2, _ballY = 0.5, _vx = 0, _vy = 0;
  double _renderX = _aspect / 2, _renderY = 0.5; // guest-side smoothed ball
  int _hostScore = 0, _guestScore = 0;
  String _phase = 'countdown'; // countdown | playing | ended
  String? _winner;
  int? _startAt;
  Duration _lastFrame = Duration.zero;
  int _lastSend = 0;

  @override
  void initState() {
    super.initState();
    _game = ref.read(liveGameControllerProvider.notifier);
    _peerName = ref.read(liveGameControllerProvider).peerName ?? 'Opponent';
    _moveSub = _game.moves.listen(_onMove);
    _endSub = _game.ends.listen(_onRemoteEnd);
    if (widget.isHost) {
      _startAt = DateTime.now().millisecondsSinceEpoch + _serveDelayMs;
      _game.sendMove({'type': 'pong-init', 'startAt': _startAt});
    }
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _moveSub?.cancel();
    _endSub?.cancel();
    _game.leaveOnScreenClosed();
    super.dispose();
  }

  void _onMove(Map<String, dynamic> move) {
    switch (move['type']) {
      case 'pong-init':
        _startAt = (move['startAt'] as num).toInt();
      case 'pong-state':
        final s = (move['state'] as Map).cast<String, dynamic>();
        _ballX = (s['ballX'] as num).toDouble();
        _ballY = (s['ballY'] as num).toDouble();
        _peerY = (s['hostY'] as num).toDouble();
        _hostScore = (s['hostScore'] as num).toInt();
        _guestScore = (s['guestScore'] as num).toInt();
      case 'pong-paddle':
        _peerY = (move['y'] as num).toDouble();
    }
  }

  void _onRemoteEnd(Map<String, dynamic> result) {
    if (!mounted) return;
    setState(() {
      _phase = 'ended';
      _winner = result['winner'] as String?;
      _hostScore = (result['hostScore'] as num?)?.toInt() ?? _hostScore;
      _guestScore = (result['guestScore'] as num?)?.toInt() ?? _guestScore;
    });
  }

  void _onTick(Duration elapsed) {
    if (!mounted || _phase == 'ended') return;
    final dt = _lastFrame == Duration.zero ? 0.0 : min(0.05, (elapsed - _lastFrame).inMicroseconds / 1e6);
    _lastFrame = elapsed;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (widget.isHost) {
      if (_phase == 'countdown') {
        if (now >= _startAt!) {
          _phase = 'playing';
          _resetBall();
        }
      } else {
        _stepPhysics(dt);
      }
      if (_phase != 'ended' && now - _lastSend >= _broadcastMs) {
        _lastSend = now;
        _game.sendMove({
          'type': 'pong-state',
          'state': {'ballX': _ballX, 'ballY': _ballY, 'hostY': _myY, 'hostScore': _hostScore, 'guestScore': _guestScore},
        });
      }
    } else {
      if (_phase == 'countdown') {
        if (_startAt != null && now >= _startAt!) _phase = 'playing';
      } else {
        // Host only broadcasts ~20×/s -- ease toward the latest position so
        // the ball still moves smoothly at the screen's frame rate.
        final t = 1 - pow(0.7, dt * 60).toDouble();
        _renderX += (_ballX - _renderX) * t;
        _renderY += (_ballY - _renderY) * t;
      }
      if (now - _lastSend >= _broadcastMs) {
        _lastSend = now;
        _game.sendMove({'type': 'pong-paddle', 'y': _myY});
      }
    }
    setState(() {});
  }

  void _stepPhysics(double dt) {
    final prevX = _ballX;
    _ballX += _vx * dt;
    _ballY += _vy * dt;

    if (_ballY - _ballR <= 0 || _ballY + _ballR >= 1) {
      _vy = -_vy;
      _ballY = _ballY.clamp(_ballR, 1 - _ballR);
    }

    // Plane-crossing test so a fast ball can't tunnel through a paddle.
    const leftPlane = _paddleXInset + _paddleHalfW + _ballR;
    const rightPlane = _aspect - _paddleXInset - _paddleHalfW - _ballR;

    if (_vx < 0 && prevX > leftPlane && _ballX <= leftPlane && (_ballY - _myY).abs() <= _paddleHalfH) {
      _ballX = leftPlane;
      _bounce(_myY, 1);
    } else if (_vx > 0 && prevX < rightPlane && _ballX >= rightPlane && (_ballY - _peerY).abs() <= _paddleHalfH) {
      _ballX = rightPlane;
      _bounce(_peerY, -1);
    } else if (_ballX < -0.1) {
      _guestScore++;
      _onScore();
    } else if (_ballX > _aspect + 0.1) {
      _hostScore++;
      _onScore();
    }
  }

  void _bounce(double paddleY, int dirSign) {
    final offset = ((_ballY - paddleY) / _paddleHalfH).clamp(-1.0, 1.0);
    final speed = min(_maxSpeed, sqrt(_vx * _vx + _vy * _vy) * _speedUp);
    final angle = offset * 0.9; // steeper hits nearer the paddle's edge
    _vx = cos(angle) * speed * dirSign;
    _vy = sin(angle) * speed;
  }

  void _resetBall() {
    _ballX = _aspect / 2;
    _ballY = 0.5;
    final angle = _rnd.nextDouble() * 0.6 - 0.3;
    final dir = _rnd.nextDouble() < 0.5 ? -1 : 1;
    _vx = cos(angle) * _baseSpeed * dir;
    _vy = sin(angle) * _baseSpeed;
  }

  void _onScore() {
    if (_hostScore < _winScore && _guestScore < _winScore) {
      _resetBall();
      return;
    }
    _phase = 'ended';
    _winner = _hostScore > _guestScore ? 'host' : 'guest';
    _vx = 0;
    _vy = 0;
    _game.sendEnd({'winner': _winner, 'hostScore': _hostScore, 'guestScore': _guestScore});
  }

  void _setPaddle(double localY, double height) {
    if (_phase == 'ended' || height <= 0) return;
    _myY = (localY / height).clamp(_paddleHalfH, 1 - _paddleHalfH);
  }

  String? get _statusLine {
    if (_phase == 'countdown') {
      final secs = max(0, (((_startAt ?? DateTime.now().millisecondsSinceEpoch) - DateTime.now().millisecondsSinceEpoch) / 1000).ceil());
      return secs > 0 ? 'Get ready… $secs' : 'Go!';
    }
    if (_phase == 'ended') {
      final iWon = (widget.isHost && _winner == 'host') || (!widget.isHost && _winner == 'guest');
      return iWon ? '🎉 You won!' : '$_peerName won.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(liveGameControllerProvider, (prev, next) {
      if (next.phase != LiveGamePhase.playing && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
    final myScore = widget.isHost ? _hostScore : _guestScore;
    final peerScore = widget.isHost ? _guestScore : _hostScore;

    return Scaffold(
      appBar: AppBar(
        title: const Text('🏓 Pong'),
        actions: [IconButton(icon: const Icon(Icons.exit_to_app_rounded), onPressed: () => _game.leaveGame())],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Column(children: [const Text('You', style: TextStyle(color: Colors.white70)), Text('$myScore', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))]),
                const Text('🏓', style: TextStyle(fontSize: 22)),
                Column(children: [Text(_peerName, style: const TextStyle(color: Colors.white70)), Text('$peerScore', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))]),
              ],
            ),
          ),
          if (_statusLine != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_statusLine!, style: const TextStyle(fontSize: 18, color: VeyonColors.bubbleMe2)),
            ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: AspectRatio(
                  aspectRatio: _aspect,
                  child: LayoutBuilder(
                    builder: (context, c) => GestureDetector(
                      onPanDown: (d) => _setPaddle(d.localPosition.dy, c.maxHeight),
                      onPanUpdate: (d) => _setPaddle(d.localPosition.dy, c.maxHeight),
                      child: CustomPaint(
                        size: Size(c.maxWidth, c.maxHeight),
                        painter: _CourtPainter(
                          myX: widget.isHost ? _paddleXInset : _aspect - _paddleXInset,
                          peerX: widget.isHost ? _aspect - _paddleXInset : _paddleXInset,
                          myY: _myY,
                          peerY: _peerY,
                          ballX: widget.isHost ? _ballX : _renderX,
                          ballY: widget.isHost ? _ballY : _renderY,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Drag up/down on the court to move your paddle', style: TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _CourtPainter extends CustomPainter {
  final double myX, peerX, myY, peerY, ballX, ballY;
  _CourtPainter({required this.myX, required this.peerX, required this.myY, required this.peerY, required this.ballX, required this.ballY});

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height, w = size.width;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0C0F18));

    final dash = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 2;
    for (double y = 0; y < h; y += 14) {
      canvas.drawLine(Offset(w / 2, y), Offset(w / 2, min(h, y + 6)), dash);
    }

    void paddle(double xUnits, double yFrac, Color color) {
      final pw = _paddleHalfW * 2 * h, ph = _paddleHalfH * 2 * h;
      final rect = Rect.fromLTWH(xUnits * h - pw / 2, yFrac * h - ph / 2, pw, ph);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(min(6, pw / 2))), Paint()..color = color);
    }

    paddle(myX, myY, const Color(0xFFA76BC9));
    paddle(peerX, peerY, const Color(0xFF7EE8C0));
    canvas.drawCircle(Offset(ballX * h, ballY * h), _ballR * h, Paint()..color = const Color(0xFFF3ECFA));
  }

  @override
  bool shouldRepaint(covariant _CourtPainter old) => true;
}
