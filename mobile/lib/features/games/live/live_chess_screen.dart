import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme.dart';
import '../chess/chess_logic.dart';
import 'live_game_controller.dart';

/// Live 1:1 chess against a chat peer -- same board rendering as the
/// offline ChessScreen, but moves are relayed over game-signal instead of
/// played against a local AI. Board orientation is not flipped for Black
/// (both players see the same absolute orientation) -- a simplification
/// versus the web client, not a bug.
class LiveChessScreen extends ConsumerStatefulWidget {
  const LiveChessScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const LiveChessScreen());

  @override
  ConsumerState<LiveChessScreen> createState() => _LiveChessScreenState();
}

class _LiveChessScreenState extends ConsumerState<LiveChessScreen> {
  int? _selected;
  List<Move> _selectedMoves = const [];
  late final LiveGameController _game;

  @override
  void initState() {
    super.initState();
    _game = ref.read(liveGameControllerProvider.notifier);
  }

  @override
  void dispose() {
    _game.leaveOnScreenClosed();
    super.dispose();
  }

  void _tapSquare(LiveGameState game, int sq) {
    final board = game.board;
    if (board == null) return;
    final myTurn = board.whiteToMove == game.myColorWhite;
    if (!myTurn || board.isGameOver) return;
    final piece = board.squares[sq];

    if (_selected != null) {
      final move = _selectedMoves.firstWhere((m) => m.to == sq, orElse: () => const Move(-1, -1));
      if (move.from != -1) {
        ref.read(liveGameControllerProvider.notifier).makeMove(move);
        setState(() {
          _selected = null;
          _selectedMoves = const [];
        });
        return;
      }
    }

    if (piece != null && piece.white == game.myColorWhite) {
      setState(() {
        _selected = sq;
        _selectedMoves = board.legalMovesFrom(sq);
      });
    } else {
      setState(() {
        _selected = null;
        _selectedMoves = const [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(liveGameControllerProvider, (prev, next) {
      if (next.phase != LiveGamePhase.playing && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
    final game = ref.watch(liveGameControllerProvider);
    final board = game.board;

    return Scaffold(
      appBar: AppBar(
        title: Text('Chess vs ${game.peerName ?? ''}'),
        actions: [
          IconButton(icon: const Icon(Icons.exit_to_app_rounded), onPressed: () => ref.read(liveGameControllerProvider.notifier).leaveGame()),
        ],
      ),
      body: board == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text(_status(board, game.myColorWhite, game.peerName ?? 'opponent'), style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text("You're playing ${game.myColorWhite ? 'White ♔' : 'Black ♚'}", style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: GridView.builder(
                        padding: EdgeInsets.zero,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8),
                        itemCount: 64,
                        itemBuilder: (context, i) => _LiveSquare(
                          piece: board.squares[i],
                          dark: ((i ~/ 8) + (i % 8)) % 2 == 1,
                          selected: _selected == i,
                          isTarget: _selectedMoves.any((m) => m.to == i),
                          onTap: () => _tapSquare(game, i),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  String _status(ChessBoard board, bool myColorWhite, String peerName) {
    if (board.isCheckmate) return (board.whiteToMove != myColorWhite) ? '🎉 Checkmate — you win!' : 'Checkmate — you lose.';
    if (board.isStalemate) return "Stalemate — it's a draw.";
    final myTurn = board.whiteToMove == myColorWhite;
    if (myTurn) return board.inCheck ? "Your move — you're in check!" : 'Your move';
    return 'Waiting for $peerName…${board.inCheck ? ' (in check)' : ''}';
  }
}

class _LiveSquare extends StatelessWidget {
  final Piece? piece;
  final bool dark;
  final bool selected;
  final bool isTarget;
  final VoidCallback onTap;
  const _LiveSquare({required this.piece, required this.dark, required this.selected, required this.isTarget, required this.onTap});

  static const _glyphs = {
    'wK': '♔', 'wQ': '♕', 'wR': '♖', 'wB': '♗', 'wN': '♘', 'wP': '♙',
    'bK': '♚', 'bQ': '♛', 'bR': '♜', 'bB': '♝', 'bN': '♞', 'bP': '♟',
  };

  @override
  Widget build(BuildContext context) {
    final key = piece == null ? null : '${piece!.white ? 'w' : 'b'}${piece!.symbol}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: selected ? VeyonColors.bubbleMe.withValues(alpha: 0.6) : (dark ? const Color(0xFF3B4252) : const Color(0xFFD8DEE9)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (key != null) Text(_glyphs[key] ?? '', style: const TextStyle(fontSize: 26)),
            if (isTarget) Container(width: 14, height: 14, decoration: const BoxDecoration(color: Colors.black26, shape: BoxShape.circle)),
          ],
        ),
      ),
    );
  }
}
