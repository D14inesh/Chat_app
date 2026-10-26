/// Faithful port of app.js's simplified 2-player Ludo rules (app.js:7466-
/// 7550) -- a single 52-cell ring (not the traditional 4-arm cross board),
/// 4 tokens per side, roll-a-6-to-leave-yard, capture-by-landing (except on
/// the 4 safe cells), an extra turn on rolling a 6, first to get all 4
/// tokens home wins. Deterministic given (dice, tokenIndex), which is what
/// lets both sides of a live match mirror each other exactly by replaying
/// just those two numbers rather than syncing full board state.
library ludo_logic;

const ludoRingLen = 52;
const ludoSafe = {0, 13, 26, 39};
const ludoEntry = {'host': 0, 'guest': 26};

int ludoAbsPos(String player, int steps) => (ludoEntry[player]! + steps) % ludoRingLen;

List<int> ludoLegalTokens(List<int> tokens, int dice) {
  final legal = <int>[];
  for (var i = 0; i < tokens.length; i++) {
    final steps = tokens[i];
    if (steps >= ludoRingLen) continue;
    if (steps == -1) {
      if (dice == 6) legal.add(i);
      continue;
    }
    if (steps + dice <= ludoRingLen) legal.add(i);
  }
  return legal;
}

class LudoState {
  final List<int> host;
  final List<int> guest;
  final String turn;
  final int? dice;
  final String? winner;

  const LudoState({
    this.host = const [-1, -1, -1, -1],
    this.guest = const [-1, -1, -1, -1],
    this.turn = 'host',
    this.dice,
    this.winner,
  });

  List<int> tokensOf(String player) => player == 'host' ? host : guest;

  LudoState copyWith({List<int>? host, List<int>? guest, String? turn, int? dice, bool clearDice = false, String? winner}) => LudoState(
        host: host ?? this.host,
        guest: guest ?? this.guest,
        turn: turn ?? this.turn,
        dice: clearDice ? null : (dice ?? this.dice),
        winner: winner ?? this.winner,
      );

  /// A player just rolled `dice` -- if they have no legal token to move,
  /// the turn silently passes (matching app.js's applyLudoRoll).
  LudoState applyRoll(int dice) {
    if (winner != null) return this;
    if (ludoLegalTokens(tokensOf(turn), dice).isEmpty) {
      return copyWith(clearDice: true, turn: turn == 'host' ? 'guest' : 'host');
    }
    return copyWith(dice: dice);
  }

  /// The active player picked which of their tokens to move with the
  /// pending dice roll -- moves it, applies capture, checks for a win, and
  /// advances the turn (unless a 6 was rolled, which grants another turn).
  LudoState applyPick(int tokenIndex) {
    if (winner != null || dice == null) return this;
    final player = turn;
    final opponent = player == 'host' ? 'guest' : 'host';
    final tokens = List<int>.of(tokensOf(player));
    tokens[tokenIndex] = tokens[tokenIndex] == -1 ? 0 : tokens[tokenIndex] + dice!;

    var opponentTokens = List<int>.of(tokensOf(opponent));
    if (tokens[tokenIndex] < ludoRingLen) {
      final landedAbs = ludoAbsPos(player, tokens[tokenIndex]);
      if (!ludoSafe.contains(landedAbs)) {
        opponentTokens = opponentTokens
            .map((s) => (s >= 0 && s < ludoRingLen && ludoAbsPos(opponent, s) == landedAbs) ? -1 : s)
            .toList();
      }
    }

    final rolledSix = dice == 6;
    final won = tokens.every((s) => s >= ludoRingLen);
    final nextTurn = won ? player : (rolledSix ? player : opponent);

    final newHost = player == 'host' ? tokens : opponentTokens;
    final newGuest = player == 'host' ? opponentTokens : tokens;
    return LudoState(host: newHost, guest: newGuest, turn: nextTurn, dice: null, winner: won ? player : null);
  }
}

/// The 52-cell ring's (row, col) positions on a 14x14 perimeter -- exact
/// port of app.js's LUDO_RING generator (top row L->R, right column T->B,
/// bottom row R->L, left column B->T).
List<List<int>> buildLudoRing() {
  const n = 14;
  final cells = <List<int>>[];
  for (var c = 0; c < n; c++) {
    cells.add([0, c]);
  }
  for (var r = 1; r < n; r++) {
    cells.add([r, n - 1]);
  }
  for (var c = n - 2; c >= 0; c--) {
    cells.add([n - 1, c]);
  }
  for (var r = n - 2; r >= 1; r--) {
    cells.add([r, 0]);
  }
  return cells;
}
