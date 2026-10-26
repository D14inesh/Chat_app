import 'package:flutter/material.dart';

import '../../theme.dart';
import '../ai/ai_chat_screen.dart';
import 'chess/chess_screen.dart';
import 'puzzle/puzzle_screen.dart';

/// Offline games — the same menu as the website's Games window. Live 1:1
/// games against a chat contact are started from inside a chat.
class GamesHomeScreen extends StatelessWidget {
  const GamesHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    return Scaffold(
      appBar: AppBar(title: const Text('Games')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _GameCard(
            icon: Icons.smart_toy_rounded,
            title: 'Chess vs computer',
            subtitle: 'Easy, Medium or Hard — works offline',
            onTap: () => open(const ChessScreen()),
          ),
          const SizedBox(height: 12),
          _GameCard(
            icon: Icons.quiz_rounded,
            title: 'Trivia quiz',
            subtitle: '5 questions per round',
            onTap: () => open(const TriviaScreen()),
          ),
          const SizedBox(height: 12),
          _GameCard(
            icon: Icons.people_alt_rounded,
            title: 'Chess — 2 players',
            subtitle: 'Pass & play on one phone',
            onTap: () => open(const ChessScreen(vsComputer: false)),
          ),
          const SizedBox(height: 12),
          _GameCard(
            icon: Icons.grid_view_rounded,
            title: 'Sliding Puzzle',
            subtitle: 'Classic 15-puzzle',
            onTap: () => open(const PuzzleScreen()),
          ),
        ],
      ),
    );
  }
}

class _GameCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _GameCard({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF141A33),
      child: ListTile(
        leading: CircleAvatar(backgroundColor: VeyonColors.bubbleMe, child: Icon(icon, color: Colors.white)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}
