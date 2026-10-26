/// Live 1:1 games against a chat peer, relayed through the single
/// `game-signal` WS frame type (the server is a pure pass-through -- it
/// validates membership/blocking but never interprets `data`).
///
/// Speaks the website's exact protocol (app.js sendGameSignal/onGameSignal)
/// so a phone player and a browser player can play each other:
///   {kind:'invite', game}            game: chess | ludo | candy-crush | pong
///   {kind:'accept'} / {kind:'decline', reason?:'busy'} / {kind:'leave'}
///   {kind:'move', move:{type, ...}}  per-game payloads, see each screen
///   {kind:'end', result}             candy-crush and pong only
/// The inviter is the host (chess: white; ludo: moves first; candy/pong:
/// picks the seed / runs the physics).
library live_game_controller;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/nav_key.dart';
import '../../auth/session.dart';
import '../../conversations/conversations_provider.dart';
import '../chess/chess_logic.dart';
import 'candy_crush_screen.dart';
import 'live_chess_screen.dart';
import 'ludo_screen.dart';
import 'pong_screen.dart';
import 'snakes_screen.dart';
import 'tictactoe_screen.dart';

enum LiveGamePhase { idle, inviteSent, inviteReceived, playing }

/// The website's LIVE_GAMES table.
const liveGames = <String, ({String label, String emoji})>{
  'ludo': (label: 'Ludo', emoji: '🎲'),
  'chess': (label: 'Chess', emoji: '♟️'),
  'candy-crush': (label: 'Candy Crush', emoji: '🍬'),
  'pong': (label: 'Pong', emoji: '🏓'),
  'tictactoe': (label: 'Tic-tac-toe', emoji: '❌'),
  'snakes': (label: 'Snake & Ladder', emoji: '🐍'),
};

class LiveGameState {
  final LiveGamePhase phase;
  final String? conversationId;
  final String? peerUserId;
  final String? peerName;
  final String game;
  final bool isHost;
  final ChessBoard? board;

  const LiveGameState({
    this.phase = LiveGamePhase.idle,
    this.conversationId,
    this.peerUserId,
    this.peerName,
    this.game = 'chess',
    this.isHost = true,
    this.board,
  });

  bool get myColorWhite => isHost;

  LiveGameState copyWith({
    LiveGamePhase? phase,
    String? conversationId,
    String? peerUserId,
    String? peerName,
    String? game,
    bool? isHost,
    ChessBoard? board,
  }) =>
      LiveGameState(
        phase: phase ?? this.phase,
        conversationId: conversationId ?? this.conversationId,
        peerUserId: peerUserId ?? this.peerUserId,
        peerName: peerName ?? this.peerName,
        game: game ?? this.game,
        isHost: isHost ?? this.isHost,
        board: board ?? this.board,
      );
}

class LiveGameController extends StateNotifier<LiveGameState> {
  final Session session;
  final String Function(String conversationId) _nameFor;
  StreamSubscription<Map<String, dynamic>>? _wsSub;

  final _moves = StreamController<Map<String, dynamic>>.broadcast();
  final _ends = StreamController<Map<String, dynamic>>.broadcast();

  /// The `move` payloads of the active game, for its screen to apply.
  Stream<Map<String, dynamic>> get moves => _moves.stream;

  /// The `result` of a remote `end` (candy-crush / pong).
  Stream<Map<String, dynamic>> get ends => _ends.stream;

  LiveGameController(this.session, this._nameFor) : super(const LiveGameState()) {
    _wsSub = session.ws?.frames.listen(_onFrame);
  }

  void _send(Map<String, dynamic> data) {
    session.ws?.send({
      'type': 'game-signal',
      'conversationId': state.conversationId,
      'toUserId': state.peerUserId,
      'data': data,
    });
  }

  void _toast(String text) {
    final ctx = veyonNavigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(content: Text(text)));
  }

  void _onFrame(Map<String, dynamic> frame) {
    if (frame['type'] != 'game-signal') return;
    final data = (frame['data'] as Map?)?.cast<String, dynamic>();
    final fromUserId = frame['fromUserId'] as String?;
    final conversationId = frame['conversationId'] as String?;
    if (data == null || fromUserId == null || conversationId == null) return;

    if (data['kind'] == 'invite') {
      if (state.phase != LiveGamePhase.idle) {
        session.ws?.send({
          'type': 'game-signal',
          'conversationId': conversationId,
          'toUserId': fromUserId,
          'data': {'kind': 'decline', 'reason': 'busy'},
        });
        return;
      }
      final game = data['game'] as String? ?? 'chess';
      state = LiveGameState(
        phase: LiveGamePhase.inviteReceived,
        conversationId: conversationId,
        peerUserId: fromUserId,
        peerName: _nameFor(conversationId),
        game: game == 'candy' ? 'candy-crush' : game,
        isHost: false,
      );
      return;
    }

    // Anything else only matters if it's about the game we're currently in.
    if (state.phase == LiveGamePhase.idle || state.conversationId != conversationId || state.peerUserId != fromUserId) return;

    switch (data['kind']) {
      case 'accept':
        if (state.phase != LiveGamePhase.inviteSent) return;
        _start();
      case 'decline':
        _toast('${state.peerName} declined${data['reason'] == 'busy' ? ' — already in a game' : ''}.');
        reset();
      case 'move':
        if (state.phase != LiveGamePhase.playing) return;
        final move = (data['move'] as Map?)?.cast<String, dynamic>();
        if (move == null) return;
        if (state.game == 'chess' && move['type'] == 'chess-move') {
          _applyChess(move['from'], move['to']);
        } else {
          _moves.add(move);
        }
      case 'end':
        final result = (data['result'] as Map?)?.cast<String, dynamic>();
        if (result != null) _ends.add(result);
      case 'leave':
        if (state.phase == LiveGamePhase.playing || state.phase == LiveGamePhase.inviteSent) {
          _toast('${state.peerName} left the game.');
        }
        reset();
    }
  }

  void _start() {
    state = state.copyWith(phase: LiveGamePhase.playing, board: state.game == 'chess' ? ChessBoard.initial() : null);
    final nav = veyonNavigatorKey.currentState;
    switch (state.game) {
      case 'pong':
        nav?.push(PongScreen.route(isHost: state.isHost));
      case 'candy-crush':
        nav?.push(CandyCrushScreen.route(isHost: state.isHost));
      case 'ludo':
        nav?.push(LudoScreen.route(isHost: state.isHost));
      case 'tictactoe':
        nav?.push(TicTacToeScreen.route(isHost: state.isHost));
      case 'snakes':
        nav?.push(SnakesScreen.route(isHost: state.isHost));
      default:
        nav?.push(LiveChessScreen.route());
    }
  }

  void sendInvite({
    required String conversationId,
    required String peerUserId,
    required String peerName,
    String game = 'chess',
  }) {
    if (state.phase != LiveGamePhase.idle) {
      _toast('Finish or leave your current game first.');
      return;
    }
    if (game == 'candy') game = 'candy-crush';
    state = LiveGameState(
      phase: LiveGamePhase.inviteSent,
      conversationId: conversationId,
      peerUserId: peerUserId,
      peerName: peerName,
      game: game,
      isHost: true,
    );
    _send({'kind': 'invite', 'game': game});
  }

  void respondToInvite(bool accept) {
    if (state.phase != LiveGamePhase.inviteReceived) return;
    if (accept) {
      _send({'kind': 'accept'});
      _start();
    } else {
      _send({'kind': 'decline'});
      reset();
    }
  }

  /// Sends one move of the active game: `{kind:'move', move}`.
  void sendMove(Map<String, dynamic> move) => _send({'kind': 'move', 'move': move});

  /// Sends the end-of-round result (candy-crush / pong).
  void sendEnd(Map<String, dynamic> result) => _send({'kind': 'end', 'result': result});

  // Chess squares travel as [row, col] (row 0 = black's back rank) -- the
  // same square numbering chess_logic.dart uses as row*8+col.
  void _applyChess(dynamic from, dynamic to) {
    final board = state.board;
    if (board == null || board.isGameOver || from is! List || to is! List) return;
    final move = Move((from[0] as num).toInt() * 8 + (from[1] as num).toInt(), (to[0] as num).toInt() * 8 + (to[1] as num).toInt());
    state = state.copyWith(board: board.applyMove(move));
  }

  void makeMove(Move move) {
    if (state.board == null) return;
    state = state.copyWith(board: state.board!.applyMove(move));
    sendMove({
      'type': 'chess-move',
      'from': [move.from ~/ 8, move.from % 8],
      'to': [move.to ~/ 8, move.to % 8],
    });
  }

  void leaveGame() {
    if (state.phase != LiveGamePhase.idle) _send({'kind': 'leave'});
    reset();
  }

  /// Called when a game screen goes away (e.g. the back button) so the peer
  /// is told and we don't stay "busy" for future invites. Deferred because
  /// providers can't be modified while the widget tree is being torn down.
  void leaveOnScreenClosed() {
    Future.microtask(() {
      if (mounted && state.phase == LiveGamePhase.playing) leaveGame();
    });
  }

  void reset() => state = const LiveGameState();

  @override
  void dispose() {
    _wsSub?.cancel();
    _moves.close();
    _ends.close();
    super.dispose();
  }
}

final liveGameControllerProvider = StateNotifierProvider<LiveGameController, LiveGameState>((ref) {
  final session = ref.watch(sessionControllerProvider);
  return LiveGameController(session, (conversationId) {
    final convos = ref.read(conversationsProvider).valueOrNull ?? const [];
    for (final c in convos) {
      if (c.id == conversationId) return c.peer?.displayName ?? 'Someone';
    }
    return 'Someone';
  });
});
