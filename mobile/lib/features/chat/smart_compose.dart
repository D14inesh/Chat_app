/// Smart compose — the website's on-device suggestions, ported 1:1:
///   · while typing: a continuation of the sentence ("how ar" → "e you")
///   · composer empty: quick replies to the last message ("Yes / No / Maybe")
/// Learned only from MY OWN past messages already saved on this phone, plus
/// a seed set of everyday phrases. Nothing is sent anywhere.
library smart_compose;

import '../../core/local_cache.dart';

class _Entry {
  int count;
  final String value;
  _Entry(this.count, this.value);
}

final _wordRe = RegExp(r"[\p{L}\p{N}']+|[.!?,]", unicode: true);
final _plainWordRe = RegExp(r"[\p{L}\p{N}']+", unicode: true);
final _punct = RegExp(r'[.!?,]');

List<String> _tokenize(String s) => _wordRe.allMatches(s.toLowerCase()).map((m) => m.group(0)!).toList();

const _seedPhrases = [
  'how are you', 'how are you doing', "how's it going", 'how was your day',
  'what are you doing', 'what happened', 'what time', 'what about you',
  'where are you', 'where are you now', 'are you there', 'are you free',
  'are you coming', 'are you okay', 'are you busy', 'are you home',
  'see you tomorrow', 'see you soon', 'see you later', 'talk to you later',
  'talk soon', 'call you later', "i'll call you", "i'll be there",
  "i'll let you know", "i'll check and let you know", 'let me know',
  'let me check', 'let me know when you are free', 'on my way',
  'almost there', 'be there in 5 minutes', 'give me a minute',
  'good morning', 'good afternoon', 'good evening', 'good night',
  'have a good day', 'have a nice day', 'take care',
  'thank you', 'thank you so much', 'thanks a lot', 'no problem',
  'no worries', 'sounds good', 'that works for me', 'works for me',
  "i don't know", "i'm not sure", "i don't think so", 'i think so',
  "i'm on it", "i'm coming", "i'm here", "i'm busy right now",
  'can you send me', 'can you please', 'can you call me', 'could you please',
  'please call me', 'please let me know', 'did you get my message',
  'did you see', 'did you eat', 'have you eaten',
  'happy birthday', 'congratulations', 'well done', 'good luck',
  'love you', 'love you too', 'miss you', 'i miss you',
  'nice to meet you', 'it was nice talking to you',
];

const _nextWord = <String, List<String>>{
  'how': ['are', 'is', 'was', 'about', 'much', 'many', 'long', 'come', 'do'],
  'what': ['are', 'is', 'time', 'happened', 'about', 'do', 'did', 'can'],
  'where': ['are', 'is', 'do', 'did', 'can', 'have'],
  'when': ['are', 'is', 'will', 'do', 'can', 'did'],
  'why': ['are', 'is', 'did', 'do', "don't", 'not'],
  'are': ['you', 'we', 'they', "n't"],
  'is': ['it', 'that', 'this', 'everything', 'she', 'he'],
  'can': ['you', 'i', 'we', 'they'],
  'could': ['you', 'we', 'i'],
  'would': ['you', 'love', 'like'],
  'will': ['you', 'be', 'call', 'do', 'let'],
  'you': ['are', 'doing', 'there', 'free', 'okay', 'coming', 'home', 'busy', 'want'],
  'i': ['am', 'will', "don't", 'think', 'have', 'can', 'was', 'need', "'m", "'ll"],
  'we': ['are', 'can', 'will', 'should', 'need'],
  'let': ['me', 'us'],
  'me': ['know', 'a', 'the', 'when', 'if'],
  'see': ['you'],
  'talk': ['to', 'later', 'soon'],
  'thank': ['you'],
  'good': ['morning', 'night', 'afternoon', 'evening', 'idea', 'luck', 'to'],
  'please': ['call', 'let', 'send', 'help', 'come'],
  'did': ['you', 'it', 'he', 'she', 'they'],
  'have': ['you', 'a', 'to', 'been'],
  'on': ['my', 'the', 'it'],
  'in': ['a', 'the', '5', '10', 'few'],
  'call': ['you', 'me', 'him', 'her', 'back'],
  'going': ['to', 'home', 'out', 'now'],
  'want': ['to', 'a', 'some', 'me'],
  'need': ['to', 'a', 'some', 'help', 'you'],
};

final _quickReplies = <(RegExp, List<String>)>[
  (RegExp(r'\?\s*$'), ['Yes', 'No', 'Maybe']),
  (RegExp(r'\b(thanks|thank you|thx|ty)\b', caseSensitive: false), ['You’re welcome 🙂', 'Anytime', '👍']),
  (RegExp(r'\b(ok|okay|k|fine|got it)\b', caseSensitive: false), ['👍', 'Great', 'Cool']),
  (RegExp(r'\b(where are you|coming|reached|on the way)\b', caseSensitive: false), ['On my way', 'Almost there', '5 mins']),
  (RegExp(r'\b(hi|hello|hey|good morning|gm)\b', caseSensitive: false), ['Hey! 👋', 'Hi', 'Hello']),
  (RegExp(r'\b(call|calling|phone)\b', caseSensitive: false), ['Calling now', 'Call you in a bit', 'Can’t talk right now']),
  (RegExp(r'\b(sorry|my bad|apolog)', caseSensitive: false), ['It’s okay', 'No worries', 'All good']),
  (RegExp(r'\b(love you|miss you)\b', caseSensitive: false), ['❤️', 'Love you too', 'Miss you more']),
  (RegExp(r'\b(congrat|well done|great job)', caseSensitive: false), ['Thank you! 🙏', 'Thanks so much']),
];

class SmartCompose {
  SmartCompose._();
  static final instance = SmartCompose._();

  final Map<String, Map<String, int>> _bigram = {};
  final Map<String, _Entry> _phrases = {};
  bool _seeded = false;
  bool _built = false;

  void _seed() {
    if (_seeded) return;
    _seeded = true;
    for (final phrase in _seedPhrases) {
      _phrases[phrase.toLowerCase()] = _Entry(3, phrase);
      final words = _tokenize(phrase);
      for (var i = 0; i < words.length - 1; i++) {
        final next = _bigram.putIfAbsent(words[i], () => {});
        next[words[i + 1]] = (next[words[i + 1]] ?? 0) + 3;
      }
    }
    _nextWord.forEach((w, nexts) {
      final m = _bigram.putIfAbsent(w, () => {});
      for (var i = 0; i < nexts.length; i++) {
        m[nexts[i]] = (m[nexts[i]] ?? 0) + (nexts.length - i) + 2;
      }
    });
  }

  /// Learns from my own sent text messages saved on this phone.
  Future<void> build(String myId, Iterable<String> conversationIds) async {
    _seed();
    if (_built) return;
    _built = true;
    final cache = LocalCache();
    for (final id in conversationIds) {
      for (final m in await cache.loadMessages(id)) {
        if (m['senderId'] == myId && m['kind'] == 'text' && m['plaintext'] is String && m['deleted'] != true) {
          learn(m['plaintext'] as String);
        }
      }
    }
  }

  /// Learn from a message the moment it's sent, so suggestions adapt live.
  void learn(String text) {
    _seed();
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > 200) return;
    if (trimmed.length <= 80) {
      final e = _phrases[trimmed.toLowerCase()];
      e == null ? _phrases[trimmed.toLowerCase()] = _Entry(1, trimmed) : e.count++;
    }
    final words = _tokenize(trimmed);
    for (var i = 0; i < words.length - 1; i++) {
      final next = _bigram.putIfAbsent(words[i], () => {});
      next[words[i + 1]] = (next[words[i + 1]] ?? 0) + 1;
    }
  }

  /// The text to append to what's been typed, or '' if unsure.
  String predict(String raw) {
    _seed();
    final t = raw.trimRight();
    if (t.length < 2 || RegExp(r'[.!?]$').hasMatch(t)) return '';
    final low = t.toLowerCase();
    final endsWithSpace = RegExp(r'\s$').hasMatch(raw);

    // 1. A phrase you (or the seed set) use — you're re-typing its start.
    _Entry? best;
    for (final p in _phrases.values) {
      if (p.count >= 2 && p.value.length > t.length && p.value.toLowerCase().startsWith(low)) {
        if (best == null || p.count > best.count) best = p;
      }
    }
    if (best != null) {
      final rest = best.value.substring(t.length);
      return endsWithSpace ? rest.replaceFirst(RegExp(r'^\s+'), '') : rest;
    }

    // 2. Word by word.
    final words = _plainWordRe.allMatches(low).map((m) => m.group(0)!).toList();
    if (words.isEmpty) return '';
    var head = '';
    String? cursor;
    if (endsWithSpace) {
      cursor = words.last;
    } else {
      head = words.last;
      cursor = words.length >= 2 ? words[words.length - 2] : null;
      if (_bigram.containsKey(head)) {
        cursor = head;
        head = '';
      }
    }
    if (cursor == null) return '';

    final pieces = <String>[];
    if (head.isNotEmpty) {
      final next = _bigram[cursor];
      if (next == null) return '';
      var w = '';
      var wn = 0;
      next.forEach((cand, n) {
        if (cand.length > head.length && cand.startsWith(head) && n > wn && !_punct.hasMatch(cand)) {
          w = cand;
          wn = n;
        }
      });
      if (w.isEmpty || wn < 3) return '';
      pieces.add(w.substring(head.length));
      cursor = w;
    }
    for (var step = 0; step < 3; step++) {
      final next = _bigram[cursor];
      if (next == null) break;
      var w = '';
      var wn = 0;
      next.forEach((cand, n) {
        if (n > wn && !_punct.hasMatch(cand)) {
          w = cand;
          wn = n;
        }
      });
      if (w.isEmpty || wn < 3) break;
      pieces.add(pieces.isEmpty && endsWithSpace ? w : ' $w');
      cursor = w;
    }
    return pieces.join();
  }

  /// Up to three quick replies to the other person's last message.
  List<String> quickReplies(String? lastIncoming) {
    _seed();
    final t = (lastIncoming ?? '').trim();
    if (t.isEmpty) return const [];
    final out = <String>[];
    for (final (re, say) in _quickReplies) {
      if (re.hasMatch(t)) out.addAll(say);
    }
    if (out.length < 3) {
      final top = _phrases.values.where((p) => p.count >= 3 && p.value.length <= 30).toList()
        ..sort((a, b) => b.count.compareTo(a.count));
      for (final p in top) {
        if (out.length >= 3) break;
        if (!out.contains(p.value)) out.add(p.value);
      }
    }
    return out.toSet().take(3).toList();
  }
}
