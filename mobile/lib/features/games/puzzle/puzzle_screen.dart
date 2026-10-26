import 'dart:math';

import 'package:flutter/material.dart';

import '../../../theme.dart';

/// Classic 15-puzzle -- a 4x4 grid of numbered tiles with one blank; tap a
/// tile adjacent to the blank to slide it in. Shuffled by replaying random
/// legal slides from the solved state, which (unlike a random permutation)
/// always yields a solvable puzzle.
class PuzzleScreen extends StatefulWidget {
  const PuzzleScreen({super.key});

  @override
  State<PuzzleScreen> createState() => _PuzzleScreenState();
}

class _PuzzleScreenState extends State<PuzzleScreen> {
  static const _size = 4;
  late List<int> _tiles; // 0..14 = numbered tiles, 15 = blank
  int _moves = 0;

  @override
  void initState() {
    super.initState();
    _shuffle();
  }

  void _shuffle() {
    _tiles = List<int>.generate(_size * _size, (i) => i);
    var blank = _tiles.length - 1;
    final rnd = Random();
    for (var i = 0; i < 200; i++) {
      final neighbors = _neighborsOf(blank);
      final swapWith = neighbors[rnd.nextInt(neighbors.length)];
      final tmp = _tiles[blank];
      _tiles[blank] = _tiles[swapWith];
      _tiles[swapWith] = tmp;
      blank = swapWith;
    }
    setState(() => _moves = 0);
  }

  List<int> _neighborsOf(int index) {
    final r = index ~/ _size, c = index % _size;
    final result = <int>[];
    if (r > 0) result.add(index - _size);
    if (r < _size - 1) result.add(index + _size);
    if (c > 0) result.add(index - 1);
    if (c < _size - 1) result.add(index + 1);
    return result;
  }

  bool get _solved {
    for (var i = 0; i < _tiles.length - 1; i++) {
      if (_tiles[i] != i) return false;
    }
    return true;
  }

  void _tap(int index) {
    if (_solved) return;
    final blank = _tiles.indexOf(_size * _size - 1);
    if (_neighborsOf(blank).contains(index)) {
      setState(() {
        final tmp = _tiles[blank];
        _tiles[blank] = _tiles[index];
        _tiles[index] = tmp;
        _moves++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sliding Puzzle'),
        actions: [IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _shuffle)],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_solved ? 'Solved in $_moves moves! 🎉' : 'Moves: $_moves', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _size, crossAxisSpacing: 6, mainAxisSpacing: 6),
                    itemCount: _tiles.length,
                    itemBuilder: (context, i) {
                      final value = _tiles[i];
                      final isBlank = value == _size * _size - 1;
                      return GestureDetector(
                        onTap: () => _tap(i),
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: isBlank ? null : VeyonColors.bubbleGradient,
                            color: isBlank ? Colors.white10 : null,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: isBlank ? null : Text('${value + 1}', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                        ),
                      );
                    },
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
