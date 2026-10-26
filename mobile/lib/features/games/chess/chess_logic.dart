/// A compact from-scratch chess rules engine -- board representation, legal
/// move generation (with check filtering), and checkmate/stalemate
/// detection. Deliberately narrower than a full chess implementation:
/// castling and en passant are not supported, and pawns always promote to a
/// queen automatically. This is the offline "chess vs. a simple AI" game
/// (app.js's live/offline chess shares one engine on the web; here it's
/// scoped to just the offline single-player mode requested for mobile).
library chess_logic;

enum PieceType { pawn, knight, bishop, rook, queen, king }

class Piece {
  final bool white;
  final PieceType type;
  const Piece(this.white, this.type);

  String get symbol {
    const letters = {
      PieceType.pawn: 'P',
      PieceType.knight: 'N',
      PieceType.bishop: 'B',
      PieceType.rook: 'R',
      PieceType.queen: 'Q',
      PieceType.king: 'K',
    };
    return letters[type]!;
  }
}

class Move {
  final int from;
  final int to;
  const Move(this.from, this.to);

  @override
  bool operator ==(Object other) => other is Move && other.from == from && other.to == to;
  @override
  int get hashCode => from * 64 + to;
}

/// 64-square board, index = row*8+col, row 0 = rank 8 (black's back rank,
/// top of a typical on-screen board), row 7 = rank 1 (white's back rank).
class ChessBoard {
  final List<Piece?> squares;
  final bool whiteToMove;

  ChessBoard._(this.squares, this.whiteToMove);

  factory ChessBoard.initial() {
    final squares = List<Piece?>.filled(64, null);
    const backRank = [
      PieceType.rook, PieceType.knight, PieceType.bishop, PieceType.queen,
      PieceType.king, PieceType.bishop, PieceType.knight, PieceType.rook,
    ];
    for (var c = 0; c < 8; c++) {
      squares[0 * 8 + c] = Piece(false, backRank[c]);
      squares[1 * 8 + c] = const Piece(false, PieceType.pawn);
      squares[6 * 8 + c] = const Piece(true, PieceType.pawn);
      squares[7 * 8 + c] = Piece(true, backRank[c]);
    }
    return ChessBoard._(squares, true);
  }

  ChessBoard _cloneApplying(Move move) {
    final next = List<Piece?>.of(squares);
    var moving = next[move.from];
    next[move.from] = null;
    // Auto-promote a pawn that reaches the far rank -- the one deliberate
    // simplification from real chess rules, documented at the file level.
    if (moving != null && moving.type == PieceType.pawn) {
      final toRow = move.to ~/ 8;
      if (toRow == 0 || toRow == 7) moving = Piece(moving.white, PieceType.queen);
    }
    next[move.to] = moving;
    return ChessBoard._(next, !whiteToMove);
  }

  int _row(int sq) => sq ~/ 8;
  int _col(int sq) => sq % 8;
  bool _onBoard(int r, int c) => r >= 0 && r < 8 && c >= 0 && c < 8;

  /// Every square `piece`'s type attacks from `from`, ignoring whether
  /// moving there would leave its own king in check -- used both for real
  /// move generation (after filtering) and for "is this square attacked"
  /// checks (where self-check is irrelevant).
  List<int> _pseudoTargets(int from, Piece piece) {
    final r = _row(from), c = _col(from);
    final targets = <int>[];

    void slide(List<List<int>> dirs) {
      for (final d in dirs) {
        var nr = r + d[0], nc = c + d[1];
        while (_onBoard(nr, nc)) {
          final sq = nr * 8 + nc;
          final occ = squares[sq];
          if (occ == null) {
            targets.add(sq);
          } else {
            if (occ.white != piece.white) targets.add(sq);
            break;
          }
          nr += d[0];
          nc += d[1];
        }
      }
    }

    switch (piece.type) {
      case PieceType.pawn:
        final dir = piece.white ? -1 : 1;
        final startRow = piece.white ? 6 : 1;
        // Forward (non-capturing) -- only added to the movable-squares list
        // by the caller for actual moves; attacks (diagonals) are separate.
        if (_onBoard(r + dir, c) && squares[(r + dir) * 8 + c] == null) {
          targets.add((r + dir) * 8 + c);
          if (r == startRow && squares[(r + 2 * dir) * 8 + c] == null) {
            targets.add((r + 2 * dir) * 8 + c);
          }
        }
        for (final dc in [-1, 1]) {
          final nr = r + dir, nc = c + dc;
          if (_onBoard(nr, nc)) {
            final occ = squares[nr * 8 + nc];
            if (occ != null && occ.white != piece.white) targets.add(nr * 8 + nc);
          }
        }
        break;
      case PieceType.knight:
        const deltas = [[-2, -1], [-2, 1], [-1, -2], [-1, 2], [1, -2], [1, 2], [2, -1], [2, 1]];
        for (final d in deltas) {
          final nr = r + d[0], nc = c + d[1];
          if (_onBoard(nr, nc)) {
            final occ = squares[nr * 8 + nc];
            if (occ == null || occ.white != piece.white) targets.add(nr * 8 + nc);
          }
        }
        break;
      case PieceType.bishop:
        slide([[-1, -1], [-1, 1], [1, -1], [1, 1]]);
        break;
      case PieceType.rook:
        slide([[-1, 0], [1, 0], [0, -1], [0, 1]]);
        break;
      case PieceType.queen:
        slide([[-1, -1], [-1, 1], [1, -1], [1, 1], [-1, 0], [1, 0], [0, -1], [0, 1]]);
        break;
      case PieceType.king:
        for (var dr = -1; dr <= 1; dr++) {
          for (var dc = -1; dc <= 1; dc++) {
            if (dr == 0 && dc == 0) continue;
            final nr = r + dr, nc = c + dc;
            if (_onBoard(nr, nc)) {
              final occ = squares[nr * 8 + nc];
              if (occ == null || occ.white != piece.white) targets.add(nr * 8 + nc);
            }
          }
        }
        break;
    }
    return targets;
  }

  bool _isSquareAttackedBy(int square, bool byWhite) {
    for (var sq = 0; sq < 64; sq++) {
      final p = squares[sq];
      if (p == null || p.white != byWhite) continue;
      if (p.type == PieceType.pawn) {
        // Pawn attacks are diagonal only -- _pseudoTargets mixes in the
        // forward push, so check diagonals directly here instead.
        final dir = byWhite ? -1 : 1;
        final r = _row(sq), c = _col(sq);
        for (final dc in [-1, 1]) {
          if (_row(square) == r + dir && _col(square) == c + dc) return true;
        }
        continue;
      }
      if (_pseudoTargets(sq, p).contains(square)) return true;
    }
    return false;
  }

  int _findKing(bool white) => squares.indexWhere((p) => p != null && p.white == white && p.type == PieceType.king);

  bool get inCheck => _isSquareAttackedBy(_findKing(whiteToMove), !whiteToMove);

  /// All fully-legal moves for the side to move (pseudo-moves filtered down
  /// to ones that don't leave that side's own king in check).
  List<Move> legalMoves() {
    final moves = <Move>[];
    for (var sq = 0; sq < 64; sq++) {
      final p = squares[sq];
      if (p == null || p.white != whiteToMove) continue;
      for (final target in _pseudoTargets(sq, p)) {
        final move = Move(sq, target);
        final next = _cloneApplying(move);
        if (!next._isSquareAttackedBy(next._findKing(whiteToMove), next.whiteToMove)) {
          moves.add(move);
        }
      }
    }
    return moves;
  }

  List<Move> legalMovesFrom(int square) => legalMoves().where((m) => m.from == square).toList();

  /// Moves for the side to move WITHOUT the "leaves own king in check"
  /// filter — fast, for the computer opponent's search (chess_ai.dart),
  /// which instead treats capturing the king as winning.
  List<Move> pseudoMoves() {
    final moves = <Move>[];
    for (var sq = 0; sq < 64; sq++) {
      final p = squares[sq];
      if (p == null || p.white != whiteToMove) continue;
      for (final target in _pseudoTargets(sq, p)) {
        moves.add(Move(sq, target));
      }
    }
    return moves;
  }

  ChessBoard applyMove(Move move) => _cloneApplying(move);

  bool get isCheckmate => inCheck && legalMoves().isEmpty;
  bool get isStalemate => !inCheck && legalMoves().isEmpty;
  bool get isGameOver => isCheckmate || isStalemate;
}
