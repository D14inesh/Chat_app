/// The newer chat features' widgets and dialogs — polls, view-once media,
/// the pinned bar, disappearing messages, translation, chat summary and
/// export. Same behaviour and wording as the website (js/features/*).
library chat_extras;

import 'package:veyon_chat_mobile/core/bubble_ink.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../models/message.dart';
import '../../theme.dart';
import 'chat_controller.dart';

const kMaxPollOptions = 12;

// ═══════════════════════════════════════════════════════════════════
// Polls
// ═══════════════════════════════════════════════════════════════════

({List<int> counts, List<List<String>> voters, int total}) _tally(ChatMessage m, int optionCount) {
  final counts = List<int>.filled(optionCount, 0);
  final voters = List.generate(optionCount, (_) => <String>[]);
  for (final v in m.votes) {
    for (final c in (v['choices'] as List<dynamic>).cast<num>()) {
      final i = c.toInt();
      if (i >= 0 && i < optionCount) {
        counts[i]++;
        voters[i].add(v['userId'] as String);
      }
    }
  }
  return (counts: counts, voters: voters, total: m.votes.length);
}

class PollCard extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  final String? myId;
  final bool pending;
  final ValueChanged<int> onVote;
  final VoidCallback onShowVotes;
  /// Set when I may close the poll (its creator, or a group admin).
  final VoidCallback? onClose;

  const PollCard({
    super.key,
    required this.message,
    required this.mine,
    required this.myId,
    required this.pending,
    required this.onVote,
    required this.onShowVotes,
    this.onClose,
  });

  static String closesText(ChatMessage m) {
    final at = m.pollClosesAt == null ? null : DateTime.tryParse(m.pollClosesAt!)?.toLocal();
    if (at == null) return '';
    final left = at.difference(DateTime.now());
    if (left.isNegative || left == Duration.zero) return 'Closed · final results';
    if (left.inMinutes < 60) return 'Closes in ${left.inMinutes < 1 ? 1 : left.inMinutes} min';
    if (left.inHours < 48) return 'Closes in ${left.inHours} h';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return 'Closes ${days[at.weekday - 1]} ${at.day}/${at.month}';
  }

  @override
  Widget build(BuildContext context) {
    final p = message.payload;
    final options = (p?['options'] as List<dynamic>? ?? const []).cast<String>();
    if (p == null || options.isEmpty) {
      return Text('Poll could not be read', style: TextStyle(color: BubbleInk.dim(context), fontStyle: FontStyle.italic));
    }
    final multi = p['multi'] == true;
    final t = _tally(message, options.length);
    final my = {
      for (final v in message.votes)
        if (v['userId'] == myId) ...(v['choices'] as List<dynamic>).cast<num>().map((n) => n.toInt()),
    };
    final accent = Theme.of(context).colorScheme.secondary;
    final track = mine ? Colors.black.withValues(alpha: 0.18) : BubbleInk.of(context).withValues(alpha: 0.12);
    final fill = mine ? BubbleInk.of(context).withValues(alpha: 0.9) : accent;
    final closed = message.pollClosed;
    final deadline = closesText(message);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 230),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(Icons.bar_chart_rounded, size: 15, color: BubbleInk.of(context).withValues(alpha: 0.75)),
            const SizedBox(width: 4),
            Text(closed ? 'POLL · CLOSED' : 'POLL',
                style: TextStyle(color: BubbleInk.of(context).withValues(alpha: 0.75), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
            if (deadline.isNotEmpty) ...[
              const Spacer(),
              Icon(Icons.schedule_rounded, size: 12, color: BubbleInk.of(context).withValues(alpha: 0.75)),
              const SizedBox(width: 3),
              Text(deadline, style: TextStyle(color: BubbleInk.of(context).withValues(alpha: 0.8), fontSize: 11, fontWeight: FontWeight.w700)),
            ],
          ]),
          const SizedBox(height: 4),
          Text(p['question'] as String? ?? '', style: TextStyle(color: BubbleInk.of(context), fontWeight: FontWeight.w700, fontSize: 15.5)),
          const SizedBox(height: 2),
          Text(multi ? 'Select one or more' : 'Select one', style: TextStyle(color: BubbleInk.dim(context), fontSize: 11.5)),
          const SizedBox(height: 8),
          for (var i = 0; i < options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: mine ? Colors.black.withValues(alpha: 0.14) : BubbleInk.of(context).withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: pending || closed ? null : () => onVote(i),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: my.contains(i) ? (mine ? BubbleInk.dim(context) : accent) : Colors.transparent),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _check(my.contains(i), multi, mine ? BubbleInk.of(context) : accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Expanded(child: Text(options[i], style: TextStyle(color: BubbleInk.of(context), fontSize: 14))),
                                if (t.counts[i] > 0)
                                  Text('${t.counts[i]}', style: TextStyle(color: BubbleInk.of(context), fontWeight: FontWeight.w700, fontSize: 12.5)),
                              ]),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(99),
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween(end: t.total == 0 ? 0 : t.counts[i] / t.total),
                                  duration: const Duration(milliseconds: 450),
                                  curve: Curves.easeOutCubic,
                                  builder: (_, v, __) => LinearProgressIndicator(value: v, minHeight: 5, backgroundColor: track, color: fill),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Divider(height: 10, color: BubbleInk.of(context).withValues(alpha: 0.24)),
          Row(children: [
            Expanded(
              child: TextButton(
                onPressed: t.total == 0 ? null : onShowVotes,
                style: TextButton.styleFrom(foregroundColor: BubbleInk.of(context), visualDensity: VisualDensity.compact),
                child: Text(t.total == 0 ? 'No votes yet' : '${t.total} ${t.total == 1 ? 'vote' : 'votes'} · View votes',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
              ),
            ),
            if (onClose != null && !closed && !pending)
              TextButton(
                onPressed: onClose,
                style: TextButton.styleFrom(foregroundColor: mine ? BubbleInk.of(context) : VeyonColors.danger, visualDensity: VisualDensity.compact),
                child: const Text('Close poll', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
              ),
          ]),
        ],
      ),
    );
  }

  Widget _check(bool on, bool square, Color color) => Container(
        width: 20,
        height: 20,
        margin: const EdgeInsets.only(top: 1),
        decoration: BoxDecoration(
          shape: square ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: square ? BorderRadius.circular(6) : null,
          border: Border.all(color: color, width: 2),
          color: on ? color : Colors.transparent,
        ),
        child: on ? Icon(Icons.check_rounded, size: 14, color: color == Colors.white ? VeyonColors.bubbleMe : Colors.black) : null,
      );
}

Future<void> showPollVotes(BuildContext context, ChatMessage m, String Function(String userId) nameOf) {
  final p = m.payload ?? const {};
  final options = (p['options'] as List<dynamic>? ?? const []).cast<String>();
  final t = _tally(m, options.length);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
        children: [
          const Text('Poll results', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(p['question'] as String? ?? '', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          for (var i = 0; i < options.length; i++)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text(options[i], style: const TextStyle(fontWeight: FontWeight.w700))),
                      Text('${t.counts[i]} ${t.counts[i] == 1 ? 'vote' : 'votes'}',
                          style: TextStyle(color: Theme.of(ctx).colorScheme.secondary, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 8),
                    if (t.voters[i].isEmpty)
                      Text('No votes', style: TextStyle(color: BubbleInk.dim(context), fontSize: 12))
                    else
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final u in t.voters[i]) Chip(label: Text(nameOf(u)), visualDensity: VisualDensity.compact),
                      ]),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Full-screen "Create a poll" — returns `{question, options, multi}`.
Future<Map<String, dynamic>?> showPollComposer(BuildContext context) =>
    Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _PollComposer()));

class _PollComposer extends StatefulWidget {
  const _PollComposer();
  @override
  State<_PollComposer> createState() => _PollComposerState();
}

class _PollComposerState extends State<_PollComposer> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [TextEditingController(), TextEditingController()];
  bool _multi = false;
  /// Seconds until the poll closes (null = stays open), or a picked moment.
  int? _closeIn;
  DateTime? _closeAt;

  String? get _pollClosesAt {
    final at = _closeAt ?? (_closeIn == null ? null : DateTime.now().add(Duration(seconds: _closeIn!)));
    return at?.toUtc().toIso8601String();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, firstDate: now, lastDate: now.add(const Duration(days: 365)), initialDate: now.add(const Duration(days: 1)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now));
    if (t == null) return;
    final at = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    if (!at.isAfter(DateTime.now())) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a closing time in the future.')));
      return;
    }
    setState(() {
      _closeAt = at;
      _closeIn = null;
    });
  }

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _filled => _options.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();

  bool get _valid {
    final f = _filled;
    return _question.text.trim().isNotEmpty && f.length >= 2 && f.map((e) => e.toLowerCase()).toSet().length == f.length;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
        title: const Text('Create a poll'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton.icon(
              onPressed: _valid
                  ? () => Navigator.pop(context, {
                        'question': _question.text.trim(),
                        'options': _filled,
                        'multi': _multi,
                        if (_pollClosesAt != null) 'pollClosesAt': _pollClosesAt,
                      })
                  : null,
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text('Send'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Question', style: TextStyle(fontWeight: FontWeight.w600, color: VeyonColors.muted)),
          const SizedBox(height: 8),
          TextField(
            controller: _question,
            autofocus: true,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Ask something…', counterText: ''),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 18),
          const Text('Options', style: TextStyle(fontWeight: FontWeight.w600, color: VeyonColors.muted)),
          const SizedBox(height: 8),
          for (var i = 0; i < _options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: VeyonColors.muted, width: 2))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _options[i],
                      maxLength: 100,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(hintText: 'Option ${i + 1}', counterText: ''),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove option',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => setState(() {
                      if (_options.length <= 2) {
                        _options[i].clear();
                      } else {
                        _options.removeAt(i).dispose();
                      }
                    }),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _options.length >= kMaxPollOptions ? null : () => setState(() => _options.add(TextEditingController())),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add option'),
              style: OutlinedButton.styleFrom(foregroundColor: accent),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            child: SwitchListTile(
              value: _multi,
              onChanged: (v) => setState(() => _multi = v),
              title: const Text('Allow multiple answers', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('People can pick more than one option'),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Close the poll', style: TextStyle(fontWeight: FontWeight.w600, color: VeyonColors.muted)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (label, secs) in const [('Never', null), ('1 hour', 3600), ('1 day', 86400), ('3 days', 259200), ('1 week', 604800)])
              ChoiceChip(
                label: Text(label),
                selected: _closeAt == null && _closeIn == secs,
                onSelected: (_) => setState(() {
                  _closeIn = secs;
                  _closeAt = null;
                }),
              ),
            ChoiceChip(
              avatar: const Icon(Icons.event_rounded, size: 16),
              label: Text(_closeAt == null
                  ? 'Pick a date'
                  : '${_closeAt!.day}/${_closeAt!.month} ${_closeAt!.hour.toString().padLeft(2, '0')}:${_closeAt!.minute.toString().padLeft(2, '0')}'),
              selected: _closeAt != null,
              onSelected: (_) => _pickDate(),
            ),
          ]),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// View once
// ═══════════════════════════════════════════════════════════════════

class ViewOnceCard extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  final String? myId;
  final bool pending;
  final String Function(String userId) nameOf;
  final bool isGroup;
  final VoidCallback onOpen;

  const ViewOnceCard({
    super.key,
    required this.message,
    required this.mine,
    required this.myId,
    required this.pending,
    required this.nameOf,
    required this.isGroup,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final video = (message.payload?['mime'] as String? ?? '').startsWith('video/');
    final opened = message.openedBy.contains(myId);
    final ready = !mine && !opened && !pending;
    final String stateText;
    if (mine) {
      final names = message.openedBy.map(nameOf).toList();
      stateText = names.isEmpty ? 'Not opened yet' : (isGroup ? 'Opened by ${names.join(', ')}' : 'Opened');
    } else {
      stateText = opened ? 'Opened' : 'Tap to view';
    }
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: ready ? onOpen : null,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ready ? accent : Colors.transparent,
                border: Border.all(color: ready ? accent : BubbleInk.dim(context), width: 2),
                boxShadow: ready ? [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 10)] : null,
              ),
              child: Text('1', style: TextStyle(color: ready ? BubbleInk.of(context) : BubbleInk.dim(context), fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(video ? 'Video' : 'Photo', style: TextStyle(color: BubbleInk.of(context), fontWeight: FontWeight.w700)),
                Text(stateText, style: TextStyle(color: BubbleInk.dim(context), fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

const _secureChannel = MethodChannel('veyon/call');

/// Shows decrypted view-once bytes full screen, straight from memory (a
/// video goes through a temp file that's deleted on close). Screenshots are
/// blocked while it's open.
Future<void> showViewOnceViewer(BuildContext context, Uint8List bytes, String mime) =>
    Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ViewOnceViewer(bytes: bytes, mime: mime)));

class _ViewOnceViewer extends StatefulWidget {
  final Uint8List bytes;
  final String mime;
  const _ViewOnceViewer({required this.bytes, required this.mime});
  @override
  State<_ViewOnceViewer> createState() => _ViewOnceViewerState();
}

class _ViewOnceViewerState extends State<_ViewOnceViewer> {
  VideoPlayerController? _video;
  File? _tmp;

  bool get _isVideo => widget.mime.startsWith('video/');

  @override
  void initState() {
    super.initState();
    _secureChannel.invokeMethod('secureScreen', true).catchError((_) => null);
    if (_isVideo) _prepareVideo();
  }

  Future<void> _prepareVideo() async {
    final dir = await getTemporaryDirectory();
    _tmp = File('${dir.path}/vo_${DateTime.now().microsecondsSinceEpoch}');
    await _tmp!.writeAsBytes(widget.bytes, flush: true);
    final c = VideoPlayerController.file(_tmp!);
    await c.initialize();
    if (!mounted) return;
    setState(() => _video = c);
    c.play();
  }

  @override
  void dispose() {
    _secureChannel.invokeMethod('secureScreen', false).catchError((_) => null);
    _video?.dispose();
    _tmp?.delete().catchError((_) => _tmp!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Row(children: [
          CircleAvatar(radius: 13, backgroundColor: Colors.white, child: Text('1', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13))),
          SizedBox(width: 10),
          Text('View once', style: TextStyle(fontSize: 16)),
        ]),
      ),
      body: Center(
        child: _isVideo
            ? (_video == null
                ? const CircularProgressIndicator()
                : AspectRatio(aspectRatio: _video!.value.aspectRatio, child: VideoPlayer(_video!)))
            : InteractiveViewer(child: Image.memory(widget.bytes, gaplessPlayback: true)),
      ),
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text('This closes for good — it can’t be opened again.', textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted)),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Pinned bar, disappearing messages, system note
// ═══════════════════════════════════════════════════════════════════

class PinnedBar extends StatelessWidget {
  final ChatMessage pinned;
  final String? pinnedByName;
  final VoidCallback onTap;
  final VoidCallback onUnpin;
  const PinnedBar({super.key, required this.pinned, required this.pinnedByName, required this.onTap, required this.onUnpin});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.secondary;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(0, 8, 4, 8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: VeyonColors.hairline))),
          child: Row(
            children: [
              Container(width: 3, height: 34, decoration: BoxDecoration(color: accent, borderRadius: const BorderRadius.horizontal(right: Radius.circular(3)))),
              const SizedBox(width: 12),
              Icon(Icons.push_pin_rounded, size: 18, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pinned message${pinnedByName == null ? '' : ' · by $pinnedByName'}',
                        style: TextStyle(color: accent, fontSize: 11.5, fontWeight: FontWeight.w700)),
                    Text(pinned.preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
                  ],
                ),
              ),
              IconButton(tooltip: 'Unpin', icon: const Icon(Icons.close_rounded, size: 18), onPressed: onUnpin),
            ],
          ),
        ),
      ),
    );
  }
}

Future<int?> showDisappearingPicker(BuildContext context, int current) {
  var picked = current;
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.18),
                child: Icon(Icons.timer_outlined, size: 28, color: Theme.of(ctx).colorScheme.secondary),
              ),
              const SizedBox(height: 10),
              const Text('Disappearing messages', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text(
                'Make new messages in this chat vanish after a set time — for everyone in it. Messages already sent stay as they are.',
                textAlign: TextAlign.center,
                style: TextStyle(color: VeyonColors.muted, fontSize: 13.5),
              ),
              const SizedBox(height: 14),
              for (final e in kDisappearOptions.entries)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: picked == e.key ? Theme.of(ctx).colorScheme.secondary : Colors.transparent),
                  ),
                  child: RadioListTile<int>(
                    value: e.key,
                    groupValue: picked,
                    onChanged: (v) => setSheet(() => picked = v!),
                    title: Text(e.value, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              const SizedBox(height: 4),
              const Row(children: [
                Icon(Icons.info_outline_rounded, size: 16, color: VeyonColors.muted),
                SizedBox(width: 8),
                Expanded(
                  child: Text('Anyone in the chat can still copy, forward or screenshot a message before it disappears.',
                      style: TextStyle(color: VeyonColors.muted, fontSize: 12)),
                ),
              ]),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(ctx, picked), child: const Text('Save'))),
            ],
          ),
        ),
      ),
    ),
  );
}

class SystemNote extends StatelessWidget {
  final IconData icon;
  final String text;
  const SystemNote({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.fromLTRB(24, 4, 24, 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: const Color(0x24FDCB6E), borderRadius: BorderRadius.circular(14)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: const Color(0xFFFFD9A0)),
            const SizedBox(width: 8),
            Flexible(child: Text(text, style: const TextStyle(color: Color(0xFFFFD9A0), fontSize: 12.5))),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Translation, summary
// ═══════════════════════════════════════════════════════════════════

const kLanguages = <String, String>{
  'en': 'English', 'ta': 'Tamil', 'hi': 'Hindi', 'te': 'Telugu', 'ml': 'Malayalam', 'kn': 'Kannada',
  'ar': 'Arabic', 'fr': 'French', 'es': 'Spanish', 'de': 'German', 'zh': 'Chinese', 'ja': 'Japanese',
};

Future<String?> pickLanguage(BuildContext context, String current) => showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Translate to', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final e in kLanguages.entries)
                    ChoiceChip(label: Text(e.value), selected: e.key == current, onSelected: (_) => Navigator.pop(ctx, e.key)),
                ],
              ),
            ],
          ),
        ),
      ),
    );

/// `{loading}` / `{error}` / `{text, lang}` for one message's translation.
class TranslationBlock extends StatelessWidget {
  final Map<String, dynamic> t;
  final VoidCallback onHide;
  final VoidCallback onChange;
  const TranslationBlock({super.key, required this.t, required this.onHide, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final label = TextStyle(color: BubbleInk.dim(context), fontSize: 11, fontWeight: FontWeight.w700);
    Widget head(String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.translate_rounded, size: 13, color: BubbleInk.dim(context)),
          const SizedBox(width: 4),
          Text(text, style: label),
        ]);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: BubbleInk.of(context).withValues(alpha: 0.3)))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (t['loading'] == true)
            head('Translating…')
          else if (t['error'] != null)
            head(t['error'] as String)
          else ...[
            Row(mainAxisSize: MainAxisSize.min, children: [
              head(kLanguages[t['lang']] ?? 'Translation'),
              _link(context, 'Change', onChange),
              _link(context, 'Hide', onHide),
            ]),
            const SizedBox(height: 2),
            Text(t['text'] as String, style: TextStyle(color: BubbleInk.of(context), fontSize: 14.5)),
          ],
        ],
      ),
    );
  }

  Widget _link(BuildContext context, String text, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(text, style: TextStyle(color: BubbleInk.dim(context), fontSize: 11, decoration: TextDecoration.underline)),
        ),
      );
}

const kAiPrivacyNote =
    'The text of these messages is decrypted on your phone and sent to your server’s AI to do this. It isn’t stored — but it does leave end-to-end encryption.';

/// Bottom sheet that runs [load] and shows the bullet-point summary.
Future<void> showSummarySheet(BuildContext context, Future<({String summary, int count})> Function() load) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => FutureBuilder<({String summary, int count})>(
      future: load(),
      builder: (ctx, snap) {
        final accent = Theme.of(ctx).colorScheme.primary;
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Column(children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Reading the chat…', style: TextStyle(color: VeyonColors.muted))]),
          );
        } else if (snap.hasError) {
          body = Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: VeyonColors.danger.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
            child: Text(snap.error.toString().replaceFirst(RegExp(r'^(ApiException\(\d+\)|Bad state): '), ''),
                style: const TextStyle(color: Color(0xFFFFC2C2))),
          );
        } else {
          final points = snap.data!.summary.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final p in points)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: VeyonColors.hairline)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(padding: const EdgeInsets.only(top: 6), child: Icon(Icons.circle, size: 7, color: accent)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(p.replaceFirst(RegExp(r'^[•\-*]\s*'), ''), style: const TextStyle(fontSize: 14, height: 1.4))),
                  ]),
                ),
              Text('Based on the last ${snap.data!.count} messages', style: const TextStyle(color: VeyonColors.muted, fontSize: 11.5)),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: snap.data!.summary));
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Summary copied.')));
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy'),
              ),
            ],
          );
        }
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(gradient: paletteColors(null).bubbleGradient, borderRadius: BorderRadius.circular(17)),
                  child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 27),
                ),
                const SizedBox(height: 10),
                const Text('Summary', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                const Text('The last messages in this chat, in a few lines.', style: TextStyle(color: VeyonColors.muted)),
                const SizedBox(height: 14),
                body,
                const SizedBox(height: 10),
                const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline_rounded, size: 15, color: VeyonColors.muted),
                  SizedBox(width: 8),
                  Expanded(child: Text(kAiPrivacyNote, style: TextStyle(color: VeyonColors.muted, fontSize: 11.5))),
                ]),
              ],
            ),
          ),
        );
      },
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════
// Export
// ═══════════════════════════════════════════════════════════════════

String exportLineText(ChatMessage m) {
  if (m.deleted) return 'This message was deleted';
  if (m.plaintext == null) return '[could not decrypt]';
  final p = m.payload;
  switch (m.kind) {
    case 'file':
      if (m.isViewOnce) return '[view-once media]';
      return '[${m.isGif ? 'GIF' : m.isSticker ? 'Sticker' : 'File'}: ${p?['name'] ?? 'attachment'}]';
    case 'voice':
      return '[Voice message]';
    case 'location':
      return '[Location: https://www.openstreetmap.org/?mlat=${p?['lat']}&mlon=${p?['lng']}]';
    case 'contact':
      return '[Contact: ${p?['name']} ${p?['phone']}]';
    case 'poll':
      final opts = (p?['options'] as List<dynamic>? ?? const []);
      return '[Poll] ${p?['question']} — ${[for (var i = 0; i < opts.length; i++) '${i + 1}) ${opts[i]}'].join('  ')}';
    default:
      return m.plaintext!;
  }
}

String _stamp(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}, ${two(d.hour)}:${two(d.minute)}';
}

/// Writes the decrypted history to a .txt file and opens the share sheet
/// (save to Files/Drive, send by email, …).
Future<void> shareChatExport({
  required String title,
  required List<ChatMessage> messages,
  required String Function(ChatMessage m) senderName,
}) async {
  final lines = [
    'Chat with $title — exported ${_stamp(DateTime.now())}',
    'Messages were end-to-end encrypted and decrypted on this phone for this export.',
    '',
    for (final m in messages)
      '[${_stamp(DateTime.tryParse(m.createdAt)?.toLocal() ?? DateTime.now())}] ${senderName(m)}: ${exportLineText(m)}',
  ];
  final dir = await getTemporaryDirectory();
  final safe = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final file = File('${dir.path}/Chat with $safe.txt');
  await file.writeAsString(lines.join('\r\n'));
  await Share.shareXFiles([XFile(file.path, mimeType: 'text/plain')], subject: 'Chat with $title');
}
