import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme.dart';
import 'live_game_controller.dart';

/// Live Snake & Ladder — the website's protocol: `{type:'sl-roll', value}`
/// and `{type:'sl-reset'}`, same board (snakes/ladders) and rules: exact
/// roll to finish on 100, a 6 gives another turn, host starts.
class SnakesScreen extends ConsumerStatefulWidget {
  final bool isHost;
  const SnakesScreen({super.key, required this.isHost});

  static Route<void> route({required bool isHost}) => MaterialPageRoute(builder: (_) => SnakesScreen(isHost: isHost));

  @override
  ConsumerState<SnakesScreen> createState() => _SnakesScreenState();
}

const kSnakes = {16: 6, 47: 26, 49: 11, 56: 53, 62: 19, 64: 60, 87: 24, 93: 73, 95: 75, 98: 78};
const kLadders = {1: 38, 4: 14, 9: 31, 21: 42, 28: 84, 36: 44, 51: 67, 71: 91, 80: 100};

/// One step of the game — pure, the same on both sides (and the website).
class SnakesState {
  final Map<String, int> pos;
  final String turn;
  final String? winner;
  final String? lastText;
  const SnakesState({this.pos = const {'host': 0, 'guest': 0}, this.turn = 'host', this.winner, this.lastText});

  SnakesState roll(int value, String Function(String who) name) {
    if (winner != null) return this;
    final who = turn;
    final from = pos[who]!;
    var to = from + value;
    var note = '';
    if (to > 100) {
      to = from;
      note = 'needs an exact roll to finish';
    } else if (kSnakes[to] != null) {
      note = '🐍 bitten at $to, down to ${kSnakes[to]}';
      to = kSnakes[to]!;
    } else if (kLadders[to] != null) {
      note = '🪜 climbed from $to to ${kLadders[to]}';
      to = kLadders[to]!;
    }
    final won = to == 100;
    return SnakesState(
      pos: {...pos, who: to},
      turn: won || value == 6 ? who : (who == 'host' ? 'guest' : 'host'),
      winner: won ? who : null,
      lastText: '${name(who)} rolled $value → ${to == 0 ? 'start' : to}${note.isEmpty ? '' : ' · $note'}',
    );
  }
}

class _SnakesScreenState extends ConsumerState<SnakesScreen> {
  late final LiveGameController _game;
  late final String _peerName;
  StreamSubscription<Map<String, dynamic>>? _sub;
  SnakesState _s = const SnakesState();

  String get _me => widget.isHost ? 'host' : 'guest';
  String _name(String who) => who == _me ? 'You' : _peerName;

  @override
  void initState() {
    super.initState();
    _game = ref.read(liveGameControllerProvider.notifier);
    _peerName = ref.read(liveGameControllerProvider).peerName ?? 'Opponent';
    _sub = _game.moves.listen((move) {
      if (!mounted) return;
      if (move['type'] == 'sl-roll') setState(() => _s = _s.roll((move['value'] as num).toInt(), _name));
      if (move['type'] == 'sl-reset') setState(() => _s = const SnakesState());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _game.leaveOnScreenClosed();
    super.dispose();
  }

  int _cellNumber(int r, int c) {
    final fromBottom = 9 - r;
    return fromBottom * 10 + (fromBottom.isEven ? c + 1 : 10 - c);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(liveGameControllerProvider, (prev, next) {
      if (next.phase != LiveGamePhase.playing && Navigator.of(context).canPop()) Navigator.of(context).pop();
    });
    final myTurn = _s.winner == null && _s.turn == _me;
    final status = _s.winner != null
        ? (_s.winner == _me ? '🎉 You won!' : '$_peerName won')
        : myTurn
            ? 'Your turn — roll the dice'
            : 'Waiting for $_peerName…';

    return Scaffold(
      appBar: AppBar(
        title: Text('Snake & Ladder vs $_peerName'),
        actions: [IconButton(tooltip: 'Leave game', icon: const Icon(Icons.exit_to_app_rounded), onPressed: _game.leaveGame)],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(status, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(14)),
                  child: GridView.count(
                    crossAxisCount: 10,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      for (var r = 0; r < 10; r++)
                        for (var c = 0; c < 10; c++) _cell(_cellNumber(r, c), (r + c).isOdd),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(_s.lastText ?? 'Roll a 1–6 to start moving. A 6 gives another turn.',
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          if (_s.pos.values.contains(0))
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('At start: ', style: TextStyle(color: Colors.white54, fontSize: 12.5)),
                for (final who in ['host', 'guest'])
                  if (_s.pos[who] == 0) ...[_token(who), const SizedBox(width: 4), Text('${_name(who)}  ', style: const TextStyle(fontSize: 12.5))],
              ],
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _s.winner != null
                  ? FilledButton(
                      onPressed: () {
                        setState(() => _s = const SnakesState());
                        _game.sendMove({'type': 'sl-reset'});
                      },
                      child: const Text('Play again'),
                    )
                  : FilledButton.icon(
                      onPressed: myTurn
                          ? () {
                              final value = 1 + Random().nextInt(6);
                              setState(() => _s = _s.roll(value, _name));
                              _game.sendMove({'type': 'sl-roll', 'value': value});
                            }
                          : null,
                      icon: const Text('🎲', style: TextStyle(fontSize: 18)),
                      label: const Text('Roll'),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _token(String who) => Container(
        width: 13,
        height: 13,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: who == 'host' ? const Color(0xFF2F80FF) : const Color(0xFFFF8A3D),
          border: who == _me ? Border.all(color: Colors.white, width: 2) : null,
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
        ),
      );

  Widget _cell(int n, bool alt) {
    final snake = kSnakes[n];
    final ladder = kLadders[n];
    return Container(
      decoration: BoxDecoration(
        color: n == 100 ? VeyonColors.online.withValues(alpha: 0.22) : (alt ? Colors.white.withValues(alpha: 0.04) : Colors.white.withValues(alpha: 0.09)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Stack(
        children: [
          Positioned(left: 2, top: 1, child: Text('$n', style: const TextStyle(fontSize: 7.5, color: Colors.white38))),
          if (snake != null || ladder != null)
            Positioned(
              right: 1,
              bottom: 0,
              child: Text.rich(TextSpan(children: [
                TextSpan(text: snake != null ? '🐍' : '🪜', style: const TextStyle(fontSize: 10)),
                TextSpan(
                  text: '${snake ?? ladder}',
                  style: TextStyle(fontSize: 6.5, fontWeight: FontWeight.w800, color: snake != null ? VeyonColors.danger : VeyonColors.online),
                ),
              ])),
            ),
          Center(
            child: Wrap(spacing: 1, children: [
              for (final who in ['host', 'guest'])
                if (_s.pos[who] == n) _token(who),
            ]),
          ),
        ],
      ),
    );
  }
}
