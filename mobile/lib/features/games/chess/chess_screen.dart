import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../../theme.dart';
import 'chess_ai.dart';
import 'chess_logic.dart';

/// Offline chess — like the website's: against the computer (you play
/// White, it plays Black; Easy / Medium / Hard), or two players passing
/// one phone. The computer thinks in a background isolate so the screen
/// never freezes while it searches.
class ChessScreen extends StatefulWidget {
  final bool vsComputer;
  const ChessScreen({super.key, this.vsComputer = true});

  @override
  State<ChessScreen> createState() => _ChessScreenState();
}

class _ChessScreenState extends State<ChessScreen> {
  ChessBoard _board = ChessBoard.initial();
  int? _selected;
  List<Move> _selectedMoves = const [];
  bool _aiThinking = false;
  ChessLevel _level = ChessLevel.medium;
  int _game = 0; // bumps on "New game" so a late computer reply is dropped

  bool get _humanTurn => !widget.vsComputer || _board.whiteToMove;

  void _tapSquare(int sq) {
    if (_aiThinking || !_humanTurn || _board.isGameOver) return;
    final piece = _board.squares[sq];

    if (_selected != null) {
      final move = _selectedMoves.firstWhere((m) => m.to == sq, orElse: () => const Move(-1, -1));
      if (move.from != -1) {
        setState(() {
          _board = _board.applyMove(move);
          _selected = null;
          _selectedMoves = const [];
        });
        if (widget.vsComputer && !_board.isGameOver) _computerMove();
        return;
      }
    }

    if (piece != null && piece.white == _board.whiteToMove) {
      setState(() {
        _selected = sq;
        _selectedMoves = _board.legalMovesFrom(sq);
      });
    } else {
      setState(() {
        _selected = null;
        _selectedMoves = const [];
      });
    }
  }

  Future<void> _computerMove() async {
    setState(() => _aiThinking = true);
    final board = _board, level = _level, game = _game;
    final move = await Isolate.run(() => pickAiMove(board, level: level));
    if (!mounted || game != _game) return;
    setState(() {
      if (move != null) _board = _board.applyMove(move);
      _aiThinking = false;
    });
  }

  void _reset() {
    setState(() {
      _game++;
      _board = ChessBoard.initial();
      _selected = null;
      _selectedMoves = const [];
      _aiThinking = false;
    });
  }

  String get _status {
    if (widget.vsComputer) {
      if (_board.isCheckmate) return _board.whiteToMove ? 'Checkmate — the computer wins' : '🎉 Checkmate — you win!';
      if (_board.isStalemate) return 'Stalemate — draw';
      if (_aiThinking) return 'Computer is thinking…';
      if (_board.whiteToMove) return _board.inCheck ? "Your move — you're in check!" : 'Your move';
      return 'Computer to move';
    }
    if (_board.isCheckmate) return 'Checkmate — ${_board.whiteToMove ? "Black" : "White"} wins';
    if (_board.isStalemate) return 'Stalemate — draw';
    return '${_board.whiteToMove ? "White" : "Black"} to move${_board.inCheck ? " — check!" : ""}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.vsComputer ? 'Chess vs computer' : 'Chess — 2 players'),
        actions: [IconButton(tooltip: 'New game', icon: const Icon(Icons.refresh_rounded), onPressed: _reset)],
      ),
      body: Column(
        children: [
          if (widget.vsComputer) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: SegmentedButton<ChessLevel>(
                segments: [for (final l in ChessLevel.values) ButtonSegment(value: l, label: Text(l.label))],
                selected: {_level},
                onSelectionChanged: (s) => setState(() => _level = s.first),
              ),
            ),
            const Text('You play White ♔ — the computer plays Black ♚', style: TextStyle(color: Colors.white54, fontSize: 12.5)),
          ],
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_status, style: const TextStyle(fontWeight: FontWeight.w600)),
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
                  itemBuilder: (context, i) => _Square(
                    piece: _board.squares[i],
                    dark: ((i ~/ 8) + (i % 8)) % 2 == 1,
                    selected: _selected == i,
                    isTarget: _selectedMoves.any((m) => m.to == i),
                    onTap: () => _tapSquare(i),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton.icon(onPressed: _reset, icon: const Icon(Icons.refresh_rounded), label: const Text('New game')),
          ),
        ],
      ),
    );
  }
}

class _Square extends StatelessWidget {
  final Piece? piece;
  final bool dark;
  final bool selected;
  final bool isTarget;
  final VoidCallback onTap;
  const _Square({required this.piece, required this.dark, required this.selected, required this.isTarget, required this.onTap});

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
