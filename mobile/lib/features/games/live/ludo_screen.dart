import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme.dart';
import 'live_game_controller.dart';
import 'ludo_logic.dart';

/// Live 1:1 Ludo -- see ludo_logic.dart for the rules. Sync strategy: only
/// two numbers ever cross the wire (a dice roll, and which token the roller
/// picked); both sides replay the exact same pure transition functions on
/// those numbers, so the board never needs to be sent whole and can't drift
/// out of sync as long as both sides run the same logic.
class LudoScreen extends ConsumerStatefulWidget {
  final bool isHost;
  const LudoScreen({super.key, required this.isHost});

  static Route<void> route({required bool isHost}) => MaterialPageRoute(builder: (_) => LudoScreen(isHost: isHost));

  @override
  ConsumerState<LudoScreen> createState() => _LudoScreenState();
}

class _LudoScreenState extends ConsumerState<LudoScreen> {
  late final String _peerName;
  late final String _myRole; // 'host' | 'guest'
  StreamSubscription<Map<String, dynamic>>? _wsSub;

  LudoState _state = const LudoState();
  final _ring = buildLudoRing();

  @override
  void initState() {
    super.initState();
    final game = ref.read(liveGameControllerProvider);
    _peerName = game.peerName ?? 'Opponent';
    _myRole = widget.isHost ? 'host' : 'guest';
    _game = ref.read(liveGameControllerProvider.notifier);
    _wsSub = _game.moves.listen(_onMove);
  }

  late final LiveGameController _game;

  @override
  void dispose() {
    _wsSub?.cancel();
    _game.leaveOnScreenClosed();
    super.dispose();
  }

  void _send(Map<String, dynamic> move) => ref.read(liveGameControllerProvider.notifier).sendMove(move);

  // Website protocol: {type:'roll', value} and {type:'pick', tokenIndex}.
  void _onMove(Map<String, dynamic> move) {
    if (!mounted) return;
    if (move['type'] == 'roll') {
      setState(() => _state = _state.applyRoll((move['value'] as num).toInt()));
    } else if (move['type'] == 'pick') {
      setState(() => _state = _state.applyPick((move['tokenIndex'] as num).toInt()));
    }
  }

  bool get _myTurn => _state.turn == _myRole && _state.winner == null;

  void _roll() {
    if (!_myTurn || _state.dice != null) return;
    final dice = Random().nextInt(6) + 1;
    setState(() => _state = _state.applyRoll(dice));
    _send({'type': 'roll', 'value': dice});
  }

  void _pick(int tokenIndex) {
    if (!_myTurn || _state.dice == null) return;
    if (!ludoLegalTokens(_state.tokensOf(_myRole), _state.dice!).contains(tokenIndex)) return;
    setState(() => _state = _state.applyPick(tokenIndex));
    _send({'type': 'pick', 'tokenIndex': tokenIndex});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(liveGameControllerProvider, (prev, next) {
      if (next.phase != LiveGamePhase.playing && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    final legalNow = _state.dice != null && _myTurn ? ludoLegalTokens(_state.tokensOf(_myRole), _state.dice!) : const <int>[];

    return Scaffold(
      appBar: AppBar(
        title: Text('Ludo vs $_peerName'),
        actions: [IconButton(icon: const Icon(Icons.exit_to_app_rounded), onPressed: () => ref.read(liveGameControllerProvider.notifier).leaveGame())],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_status(), style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 14),
                    itemCount: 14 * 14,
                    itemBuilder: (context, i) {
                      final r = i ~/ 14, c = i % 14;
                      final ringIndex = _ring.indexWhere((cell) => cell[0] == r && cell[1] == c);
                      if (ringIndex == -1) return const SizedBox.shrink();
                      final safe = ludoSafe.contains(ringIndex);
                      final hostHere = _state.host.where((s) => s >= 0 && s < ludoRingLen && ludoAbsPos('host', s) == ringIndex).length;
                      final guestHere = _state.guest.where((s) => s >= 0 && s < ludoRingLen && ludoAbsPos('guest', s) == ringIndex).length;
                      return Container(
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(color: safe ? Colors.amber.withValues(alpha: 0.3) : Colors.white10, borderRadius: BorderRadius.circular(3)),
                        alignment: Alignment.center,
                        child: Wrap(
                          spacing: 1,
                          children: [
                            for (var k = 0; k < hostHere; k++) const _Dot(color: VeyonColors.bubbleMe),
                            for (var k = 0; k < guestHere; k++) const _Dot(color: Colors.orangeAccent),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                ElevatedButton(
                  onPressed: _myTurn && _state.dice == null ? _roll : null,
                  child: Text(_state.dice != null ? 'Rolled: ${_state.dice}' : 'Roll dice'),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: List.generate(4, (i) {
                    final steps = _state.tokensOf(_myRole)[i];
                    final label = steps == -1 ? 'Yard' : (steps >= ludoRingLen ? 'Home 🏁' : '#${steps + 1}');
                    final legal = legalNow.contains(i);
                    return ChoiceChip(
                      label: Text('Token ${i + 1}: $label'),
                      selected: false,
                      onSelected: legal ? (_) => _pick(i) : null,
                      backgroundColor: legal ? VeyonColors.bubbleMe.withValues(alpha: 0.3) : null,
                    );
                  }),
                ),
                const SizedBox(height: 8),
                Text(
                  '$_peerName: ${_state.tokensOf(_myRole == 'host' ? 'guest' : 'host').asMap().entries.map((e) => 'T${e.key + 1} ${e.value == -1 ? 'Yard' : (e.value >= ludoRingLen ? 'Home 🏁' : '#${e.value + 1}')}').join(' · ')}',
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _status() {
    if (_state.winner != null) {
      return _state.winner == _myRole ? '🎉 You won!' : '$_peerName won.';
    }
    if (_myTurn) return _state.dice == null ? 'Your turn — roll the dice' : 'You rolled ${_state.dice} — pick a token';
    return 'Waiting for $_peerName…';
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}
