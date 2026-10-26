import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme.dart';
import 'live_game_controller.dart';

/// Live Tic-tac-toe — the website's protocol: `{type:'ttt', cell}` and
/// `{type:'ttt-reset'}`. The inviter (host) is ✕ and starts the first
/// round; players take turns starting after that.
class TicTacToeScreen extends ConsumerStatefulWidget {
  final bool isHost;
  const TicTacToeScreen({super.key, required this.isHost});

  static Route<void> route({required bool isHost}) => MaterialPageRoute(builder: (_) => TicTacToeScreen(isHost: isHost));

  @override
  ConsumerState<TicTacToeScreen> createState() => _TicTacToeScreenState();
}

const _lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]];

class _TicTacToeScreenState extends ConsumerState<TicTacToeScreen> {
  late final LiveGameController _game;
  late final String _peerName;
  StreamSubscription<Map<String, dynamic>>? _sub;

  List<String?> _board = List.filled(9, null);
  String _turn = 'X';
  String _starter = 'X';
  String? _winner; // 'X' | 'O' | 'draw'
  List<int>? _line;
  final _score = {'X': 0, 'O': 0, 'draw': 0};

  String get _me => widget.isHost ? 'X' : 'O';

  @override
  void initState() {
    super.initState();
    _game = ref.read(liveGameControllerProvider.notifier);
    _peerName = ref.read(liveGameControllerProvider).peerName ?? 'Opponent';
    _sub = _game.moves.listen((move) {
      if (!mounted) return;
      if (move['type'] == 'ttt') _apply((move['cell'] as num).toInt());
      if (move['type'] == 'ttt-reset') _reset();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _game.leaveOnScreenClosed();
    super.dispose();
  }

  void _apply(int cell) {
    if (_winner != null || _board[cell] != null) return;
    setState(() {
      _board[cell] = _turn;
      final line = _lines.where((l) => _board[l[0]] != null && _board[l[0]] == _board[l[1]] && _board[l[0]] == _board[l[2]]).firstOrNull;
      if (line != null) {
        _winner = _turn;
        _line = line;
        _score[_turn] = _score[_turn]! + 1;
      } else if (_board.every((c) => c != null)) {
        _winner = 'draw';
        _score['draw'] = _score['draw']! + 1;
      } else {
        _turn = _turn == 'X' ? 'O' : 'X';
      }
    });
  }

  void _reset() => setState(() {
        _starter = _starter == 'X' ? 'O' : 'X';
        _board = List.filled(9, null);
        _turn = _starter;
        _winner = null;
        _line = null;
      });

  @override
  Widget build(BuildContext context) {
    ref.listen(liveGameControllerProvider, (prev, next) {
      if (next.phase != LiveGamePhase.playing && Navigator.of(context).canPop()) Navigator.of(context).pop();
    });
    final myTurn = _winner == null && _turn == _me;
    final status = _winner == 'draw'
        ? '🤝 It’s a draw'
        : _winner != null
            ? (_winner == _me ? '🎉 You won!' : '$_peerName won')
            : myTurn
                ? 'Your turn — you’re ${_me == 'X' ? '✕' : '◯'}'
                : 'Waiting for $_peerName…';
    final accent = Theme.of(context).colorScheme.secondary;

    return Scaffold(
      appBar: AppBar(
        title: Text('Tic-tac-toe vs $_peerName'),
        actions: [IconButton(tooltip: 'Leave game', icon: const Icon(Icons.exit_to_app_rounded), onPressed: _game.leaveGame)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(status, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 18),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: GridView.count(
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      for (var i = 0; i < 9; i++)
                        Material(
                          color: _line?.contains(i) == true ? VeyonColors.online.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.07),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: _line?.contains(i) == true ? const BorderSide(color: VeyonColors.online, width: 2) : BorderSide.none,
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: myTurn && _board[i] == null
                                ? () {
                                    _apply(i);
                                    _game.sendMove({'type': 'ttt', 'cell': i});
                                  }
                                : null,
                            child: Center(
                              child: Text(
                                _board[i] == 'X' ? '✕' : _board[i] == 'O' ? '◯' : '',
                                style: TextStyle(fontSize: 52, fontWeight: FontWeight.w800, color: _board[i] == 'X' ? accent : const Color(0xFFFDCB6E)),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _score2('You', _score[_me]!),
                _score2('Draws', _score['draw']!),
                _score2(_peerName, _score[_me == 'X' ? 'O' : 'X']!),
              ],
            ),
            const SizedBox(height: 14),
            if (_winner != null)
              FilledButton(
                onPressed: () {
                  _reset();
                  _game.sendMove({'type': 'ttt-reset'});
                },
                child: const Text('Play again'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _score2(String label, int n) => Column(children: [
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12.5)),
        Text('$n', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      ]);
}
