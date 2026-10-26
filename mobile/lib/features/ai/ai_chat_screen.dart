/// AI Chat — the website's openAiChat(): a conversation with the local AI
/// model running behind the backend (Ollama). Not end-to-end encrypted —
/// the server has to read the message to pass it to the model. When the AI
/// can't be reached, offers offline games instead of a dead end: a trivia
/// quiz, chess vs the computer or pass-and-play, or the sliding puzzle.
library ai_chat_screen;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme.dart';
import '../auth/session.dart';
import '../games/chess/chess_screen.dart';
import '../games/puzzle/puzzle_screen.dart';

class AiChatScreen extends ConsumerStatefulWidget {
  const AiChatScreen({super.key});

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<({String role, String content})> _messages = [];
  bool _loading = true;
  bool _thinking = false;
  String? _error;
  bool _offerGames = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(sessionControllerProvider).api.aiMessages();
      _messages
        ..clear()
        ..addAll(rows.cast<Map<String, dynamic>>().map((m) => (role: m['role'] as String, content: m['content'] as String)));
    } catch (_) {
      _error = 'Could not load your AI chat history.';
      _offerGames = true;
    }
    if (mounted) setState(() => _loading = false);
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (content.isEmpty || _thinking) return;
    _input.clear();
    setState(() {
      _messages.add((role: 'user', content: content));
      _thinking = true;
      _error = null;
      _offerGames = false;
    });
    _toBottom();
    try {
      final reply = await ref.read(sessionControllerProvider).api.aiSend(content);
      setState(() => _messages.add((role: 'assistant', content: reply)));
    } catch (e) {
      // Your connection dropped, or the AI service isn't running — offer
      // something to do instead.
      setState(() {
        _error = e.toString().replaceFirst(RegExp(r'^ApiException\(\d+\): '), '');
        _offerGames = true;
      });
    } finally {
      if (mounted) setState(() => _thinking = false);
      _toBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AI Chat'),
            Text('Powered by a local model · not end-to-end encrypted', style: TextStyle(fontSize: 11.5, color: VeyonColors.muted)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (_messages.isEmpty && _error == null)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Ask it anything — this chat is not end-to-end encrypted, unlike the rest of your '
                            'conversations, since the message has to be readable to send to the AI.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: VeyonColors.muted),
                          ),
                        ),
                      for (final m in _messages) _AiBubble(mine: m.role == 'user', text: m.content),
                      if (_thinking)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('Thinking…', style: TextStyle(color: VeyonColors.muted, fontStyle: FontStyle.italic)),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(_error!, style: const TextStyle(color: VeyonColors.danger)),
                        ),
                      if (_offerGames) const _OfflineGamesCard(),
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 4000,
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                      decoration: const InputDecoration(hintText: 'Message the AI…'),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(onPressed: _thinking ? null : _send, icon: const Icon(Icons.send_rounded)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiBubble extends StatelessWidget {
  final bool mine;
  final String text;
  const _AiBubble({required this.mine, required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(
          gradient: mine ? VeyonColors.bubbleGradient : null,
          color: mine ? null : const Color(0xFF1B2340),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(text, style: const TextStyle(color: Colors.white, fontSize: 14.5)),
      ),
    );
  }
}

/// "Can't reach the AI right now" — pick something to play, no connection needed.
class _OfflineGamesCard extends StatelessWidget {
  const _OfflineGamesCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Can't reach the AI right now.", style: TextStyle(fontWeight: FontWeight.w700)),
            const Text('Pick something to play while you wait — no connection needed:', style: TextStyle(color: VeyonColors.muted)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChessScreen())),
                  child: const Text('♟️ Chess vs computer'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TriviaScreen())),
                  child: const Text('Trivia quiz'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChessScreen(vsComputer: false))),
                  child: const Text('Chess — 2 players (pass & play)'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PuzzleScreen())),
                  child: const Text('Sliding puzzle'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Trivia quiz — same questions as the website, 5 per round ──────────

const _triviaBank = [
  (q: 'Which planet is known as the Red Planet?', o: ['Venus', 'Mars', 'Jupiter', 'Saturn'], a: 1),
  (q: 'What is the capital of Japan?', o: ['Seoul', 'Beijing', 'Tokyo', 'Bangkok'], a: 2),
  (q: 'Who wrote the play "Romeo and Juliet"?', o: ['Charles Dickens', 'William Shakespeare', 'Mark Twain', 'Leo Tolstoy'], a: 1),
  (q: 'What is the largest ocean on Earth?', o: ['Atlantic', 'Indian', 'Arctic', 'Pacific'], a: 3),
  (q: 'How many continents are there on Earth?', o: ['5', '6', '7', '8'], a: 2),
  (q: 'What gas do plants absorb from the atmosphere for photosynthesis?', o: ['Oxygen', 'Nitrogen', 'Carbon dioxide', 'Hydrogen'], a: 2),
  (q: 'Which country is home to the Great Barrier Reef?', o: ['Brazil', 'Australia', 'Mexico', 'Indonesia'], a: 1),
  (q: 'What is the chemical symbol for gold?', o: ['Ag', 'Au', 'Gd', 'Go'], a: 1),
  (q: 'Who painted the Mona Lisa?', o: ['Vincent van Gogh', 'Pablo Picasso', 'Leonardo da Vinci', 'Claude Monet'], a: 2),
  (q: 'What is the tallest mountain in the world?', o: ['K2', 'Kangchenjunga', 'Mount Everest', 'Lhotse'], a: 2),
  (q: 'Which is the smallest country in the world?', o: ['Monaco', 'San Marino', 'Vatican City', 'Liechtenstein'], a: 2),
  (q: 'How many strings does a standard guitar have?', o: ['4', '5', '6', '7'], a: 2),
  (q: 'What is the main language spoken in Brazil?', o: ['Spanish', 'Portuguese', 'French', 'Italian'], a: 1),
  (q: 'Which organ in the human body pumps blood?', o: ['Lungs', 'Liver', 'Kidney', 'Heart'], a: 3),
  (q: 'What is the freezing point of water in Celsius?', o: ['0°C', '32°C', '-1°C', '100°C'], a: 0),
  (q: 'Which planet has the most moons in our solar system?', o: ['Earth', 'Mars', 'Saturn', 'Mercury'], a: 2),
  (q: 'What does "www" stand for?', o: ['World Wide Web', 'World Web Wide', 'Wide World Web', 'Web World Wide'], a: 0),
  (q: 'Which ancient wonder still stands today?', o: ['Colossus of Rhodes', 'Great Pyramid of Giza', 'Hanging Gardens', 'Lighthouse of Alexandria'], a: 1),
  (q: 'What is the currency of Japan?', o: ['Won', 'Yuan', 'Yen', 'Ringgit'], a: 2),
  (q: 'Which element has the atomic number 1?', o: ['Helium', 'Hydrogen', 'Oxygen', 'Carbon'], a: 1),
];

class TriviaScreen extends StatefulWidget {
  const TriviaScreen({super.key});

  @override
  State<TriviaScreen> createState() => _TriviaScreenState();
}

class _TriviaScreenState extends State<TriviaScreen> {
  late List<({String q, List<String> o, int a})> _round;
  int _index = 0;
  int _score = 0;
  int? _picked;

  @override
  void initState() {
    super.initState();
    _newRound();
  }

  void _newRound() {
    _round = ([..._triviaBank]..shuffle(Random())).take(5).toList();
    _index = 0;
    _score = 0;
    _picked = null;
  }

  @override
  Widget build(BuildContext context) {
    final done = _index >= _round.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Trivia quiz')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: done
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$_score / ${_round.length}', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
                    const Text('nice one.', style: TextStyle(color: VeyonColors.muted)),
                    const SizedBox(height: 20),
                    FilledButton(onPressed: () => setState(_newRound), child: const Text('Play again')),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Question ${_index + 1} of ${_round.length} · Score $_score', style: const TextStyle(color: VeyonColors.muted)),
                  const SizedBox(height: 12),
                  Text(_round[_index].q, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 18),
                  for (var i = 0; i < _round[_index].o.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: _picked == null
                              ? null
                              : i == _round[_index].a
                                  ? Colors.green.withValues(alpha: 0.35)
                                  : i == _picked
                                      ? VeyonColors.danger.withValues(alpha: 0.35)
                                      : null,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _picked != null
                            ? null
                            : () => setState(() {
                                  _picked = i;
                                  if (i == _round[_index].a) _score++;
                                }),
                        child: Text(_round[_index].o[i]),
                      ),
                    ),
                  const Spacer(),
                  if (_picked != null)
                    FilledButton(
                      onPressed: () => setState(() {
                        _index++;
                        _picked = null;
                      }),
                      child: Text(_index + 1 < _round.length ? 'Next question' : 'See score'),
                    ),
                ],
              ),
      ),
    );
  }
}
