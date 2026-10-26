import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme.dart';
import 'live_game_controller.dart';

/// Live "Candy Crush" duel -- NOT a shared board. A timed duel on two
/// independent boards that start identical (same PRNG seed, chosen by the
/// host). Exact port of the website (app.js startCandyCrushGame and
/// friends) so phone and browser players can duel each other:
///   host -> {type:'candy-init', seed, startAt}   (startAt = now + 1.5 s)
///   both -> {type:'score', value}                after every scoring swap
///   both -> end {score}                          when the 90 s run out;
///   a remote end also finishes my round.
class CandyCrushScreen extends ConsumerStatefulWidget {
  final bool isHost;
  const CandyCrushScreen({super.key, required this.isHost});

  static Route<void> route({required bool isHost}) => MaterialPageRoute(builder: (_) => CandyCrushScreen(isHost: isHost));

  @override
  ConsumerState<CandyCrushScreen> createState() => _CandyCrushScreenState();
}

const _gridSize = 8;
const _emoji = ['🍬', '🍭', '🍫', '🍪', '🍩', '🍡'];
const _durationMs = 90000;

/// Bit-exact port of app.js's mulberry32, so the same seed gives the same
/// board on the phone and in the browser.
class Mulberry32 {
  static const _mask = 0xFFFFFFFF;
  int _a;
  Mulberry32(int seed) : _a = seed & _mask;

  static int _imul(int a, int b) => (a * b) & _mask;

  double next() {
    _a = (_a + 0x6D2B79F5) & _mask;
    var t = _imul(_a ^ (_a >>> 15), 1 | _a);
    t = ((t + _imul(t ^ (t >>> 7), 61 | t)) & _mask) ^ t;
    return ((t ^ (t >>> 14)) & _mask) / 4294967296.0;
  }
}

Set<int> findCandyMatches(List<int> grid) {
  const n = _gridSize;
  final toClear = <int>{};
  for (var r = 0; r < n; r++) {
    var start = 0;
    for (var c = 1; c <= n; c++) {
      final same = c < n && grid[r * n + c] == grid[r * n + start] && grid[r * n + c] != -1;
      if (!same) {
        if (c - start >= 3) {
          for (var k = start; k < c; k++) {
            toClear.add(r * n + k);
          }
        }
        start = c;
      }
    }
  }
  for (var c = 0; c < n; c++) {
    var start = 0;
    for (var r = 1; r <= n; r++) {
      final same = r < n && grid[r * n + c] == grid[start * n + c] && grid[r * n + c] != -1;
      if (!same) {
        if (r - start >= 3) {
          for (var k = start; k < r; k++) {
            toClear.add(k * n + c);
          }
        }
        start = r;
      }
    }
  }
  return toClear;
}

void applyCandyGravity(List<int> grid, Mulberry32 rand) {
  const n = _gridSize;
  for (var c = 0; c < n; c++) {
    var write = n - 1;
    for (var r = n - 1; r >= 0; r--) {
      if (grid[r * n + c] != -1) {
        grid[write * n + c] = grid[r * n + c];
        write--;
      }
    }
    for (var r = write; r >= 0; r--) {
      grid[r * n + c] = (rand.next() * _emoji.length).floor();
    }
  }
}

class _CandyCrushScreenState extends ConsumerState<CandyCrushScreen> {
  late final String _peerName;
  late final LiveGameController _game;
  StreamSubscription<Map<String, dynamic>>? _moveSub;
  StreamSubscription<Map<String, dynamic>>? _endSub;
  Timer? _tick;
  Timer? _endTimer;

  Mulberry32? _rand;
  List<int>? _grid;
  int? _selected;
  int _score = 0;
  int _peerScore = 0;
  int? _startAt;
  bool _ended = false;
  int? _myFinal;
  int? _peerFinal;

  @override
  void initState() {
    super.initState();
    _game = ref.read(liveGameControllerProvider.notifier);
    _peerName = ref.read(liveGameControllerProvider).peerName ?? 'Opponent';
    _moveSub = _game.moves.listen(_onMove);
    _endSub = _game.ends.listen(_onRemoteEnd);

    if (widget.isHost) {
      final seed = Random().nextInt(1 << 31);
      _startAt = DateTime.now().millisecondsSinceEpoch + 1500;
      _initBoard(seed);
      _game.sendMove({'type': 'candy-init', 'seed': seed, 'startAt': _startAt});
      _scheduleEnd();
    }
  }

  @override
  void dispose() {
    _moveSub?.cancel();
    _endSub?.cancel();
    _tick?.cancel();
    _endTimer?.cancel();
    _game.leaveOnScreenClosed();
    super.dispose();
  }

  void _initBoard(int seed) {
    final rand = Mulberry32(seed);
    _rand = rand;
    _grid = List<int>.generate(_gridSize * _gridSize, (_) => (rand.next() * _emoji.length).floor());
  }

  void _scheduleEnd() {
    final delay = max(0, _startAt! + _durationMs - DateTime.now().millisecondsSinceEpoch);
    _endTimer = Timer(Duration(milliseconds: delay), _finishRound);
    // Redraw once a second so the countdown visibly ticks.
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _ended) {
        t.cancel();
        return;
      }
      setState(() {});
    });
  }

  void _finishRound() {
    if (_ended || !mounted) return;
    setState(() {
      _ended = true;
      _myFinal = _score;
    });
    _game.sendEnd({'score': _score});
  }

  void _onMove(Map<String, dynamic> move) {
    if (!mounted) return;
    if (move['type'] == 'candy-init' && !widget.isHost) {
      setState(() {
        _startAt = (move['startAt'] as num).toInt();
        _initBoard((move['seed'] as num).toInt());
      });
      _scheduleEnd();
    } else if (move['type'] == 'score') {
      setState(() => _peerScore = (move['value'] as num).toInt());
    }
  }

  void _onRemoteEnd(Map<String, dynamic> result) {
    if (!mounted) return;
    final score = (result['score'] as num?)?.toInt() ?? _peerScore;
    setState(() {
      _peerFinal = score;
      _peerScore = score;
    });
    if (!_ended) _finishRound();
  }

  void _trySwap(int i, int j) {
    final grid = _grid!;
    var tmp = grid[i];
    grid[i] = grid[j];
    grid[j] = tmp;
    var matches = findCandyMatches(grid);
    if (matches.isEmpty) {
      tmp = grid[i];
      grid[i] = grid[j];
      grid[j] = tmp;
      return;
    }
    var cleared = 0;
    var chain = 0;
    while (matches.isNotEmpty) {
      cleared += matches.length;
      chain++;
      for (final idx in matches) {
        grid[idx] = -1;
      }
      applyCandyGravity(grid, _rand!);
      matches = findCandyMatches(grid);
    }
    _score += cleared * 10 + (chain - 1) * 15; // small bonus for chain reactions
    _game.sendMove({'type': 'score', 'value': _score});
  }

  void _tap(int i) {
    if (_ended || _grid == null) return;
    setState(() {
      if (_selected == null) {
        _selected = i;
        return;
      }
      if (_selected == i) {
        _selected = null;
        return;
      }
      final a = _selected!, b = i;
      final adjacent = ((a ~/ _gridSize) - (b ~/ _gridSize)).abs() + ((a % _gridSize) - (b % _gridSize)).abs() == 1;
      _selected = null;
      if (adjacent) _trySwap(a, b);
    });
  }

  String get _timerLabel {
    if (_ended) return '⏱️ 0:00';
    if (_startAt == null) return '⏱️ —';
    final remaining = max(0, ((_startAt! + _durationMs - DateTime.now().millisecondsSinceEpoch) / 1000).ceil());
    return '⏱️ ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}';
  }

  String? get _resultLine {
    if (!_ended) return null;
    if (_myFinal == null || _peerFinal == null) return 'Waiting for final score…';
    if (_myFinal == _peerFinal) return "🤝 It's a tie!";
    return _myFinal! > _peerFinal! ? '🎉 You won!' : '$_peerName won.';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(liveGameControllerProvider, (prev, next) {
      if (next.phase != LiveGamePhase.playing && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
    final grid = _grid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('🍬 Candy Crush'),
        actions: [IconButton(icon: const Icon(Icons.exit_to_app_rounded), onPressed: () => _game.leaveGame())],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ScoreBox(label: 'You', score: _score),
                Text(_timerLabel, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                _ScoreBox(label: _peerName, score: _peerScore),
              ],
            ),
          ),
          if (_resultLine != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_resultLine!, style: const TextStyle(fontSize: 18, color: VeyonColors.bubbleMe2)),
            ),
          Expanded(
            child: grid == null
                ? const Center(child: Text('Setting up the board…', style: TextStyle(color: Colors.white54)))
                : Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: GridView.builder(
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _gridSize, crossAxisSpacing: 2, mainAxisSpacing: 2),
                          itemCount: grid.length,
                          itemBuilder: (context, i) => GestureDetector(
                            onTap: () => _tap(i),
                            child: Container(
                              decoration: BoxDecoration(
                                color: _selected == i ? VeyonColors.bubbleMe.withValues(alpha: 0.4) : Colors.white10,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              alignment: Alignment.center,
                              child: Text(grid[i] == -1 ? '' : _emoji[grid[i]], style: const TextStyle(fontSize: 20)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ScoreBox extends StatelessWidget {
  final String label;
  final int score;
  const _ScoreBox({required this.label, required this.score});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white70)),
        Text('$score', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ],
    );
  }
}
