/// The computer opponent — same engine and levels as the website (app.js
/// chessComputerMove): alpha-beta search scoring material plus simple
/// positional bonuses. Inside the search, moves are pseudo-legal and
/// capturing the king ends a line (a cheap way to see mate); only the move
/// actually played is checked for full legality.
library chess_ai;

import 'dart:math';

import 'chess_logic.dart';

enum ChessLevel {
  easy('Easy', 1, 80),
  medium('Medium', 2, 15),
  hard('Hard', 4, 4);

  final String label;
  final int depth;
  final double noise;
  const ChessLevel(this.label, this.depth, this.noise);
}

const _value = {
  PieceType.pawn: 100,
  PieceType.knight: 320,
  PieceType.bishop: 330,
  PieceType.rook: 500,
  PieceType.queen: 900,
  PieceType.king: 20000,
};

double _positional(PieceType type, int r, int c, bool white) {
  final fromHome = white ? 7 - r : r; // 0 on own back rank
  final center = 3.5 - max((3.5 - r).abs(), (3.5 - c).abs());
  switch (type) {
    case PieceType.pawn:
      return (fromHome - 1) * 8 + (c >= 2 && c <= 5 ? center * 4 : 0);
    case PieceType.knight:
      return center * 10 - 15;
    case PieceType.bishop:
      return center * 6;
    case PieceType.queen:
      return center * 2;
    case PieceType.king:
      return fromHome == 0 ? 15 : -8.0 * fromHome; // keep the king home
    case PieceType.rook:
      return 0;
  }
}

/// Score for the side to move (positive = good for them).
double _evaluate(ChessBoard board) {
  var score = 0.0;
  for (var sq = 0; sq < 64; sq++) {
    final p = board.squares[sq];
    if (p == null) continue;
    final v = _value[p.type]! + _positional(p.type, sq ~/ 8, sq % 8, p.white);
    score += p.white == board.whiteToMove ? v : -v;
  }
  return score;
}

List<Move> _ordered(ChessBoard board) {
  final moves = board.pseudoMoves();
  int victim(Move m) => board.squares[m.to] == null ? 0 : _value[board.squares[m.to]!.type]!;
  moves.sort((a, b) => victim(b) - victim(a)); // captures first, best victim first
  return moves;
}

double _search(ChessBoard board, int depth, double alpha, double beta) {
  if (depth == 0) return _evaluate(board);
  final moves = _ordered(board);
  if (moves.isEmpty) return 0;
  for (final m in moves) {
    if (board.squares[m.to]?.type == PieceType.king) return 100000.0 + depth; // king falls = win
    final score = -_search(board.applyMove(m), depth - 1, -beta, -alpha);
    if (score >= beta) return score;
    if (score > alpha) alpha = score;
  }
  return alpha;
}

/// The computer's move for the side to move, or null when it has none.
/// Pure function of its inputs — safe to run in a background isolate.
Move? pickAiMove(ChessBoard board, {ChessLevel level = ChessLevel.medium}) {
  final rnd = Random();
  Move? best;
  var bestScore = double.negativeInfinity;
  for (final m in board.legalMoves()) {
    final next = board.applyMove(m);
    double score;
    if (next.legalMoves().isEmpty) {
      score = next.inCheck ? 1000000 : 0; // mate : stalemate
    } else {
      score = -_search(next, level.depth - 1, double.negativeInfinity, double.infinity);
    }
    score += (rnd.nextDouble() - 0.5) * 2 * level.noise; // a little variety; more on Easy
    if (score > bestScore) {
      bestScore = score;
      best = m;
    }
  }
  return best;
}
