/// Everyday chat-screen helpers: swipe to reply, message info, link previews
/// and the chat text size.
library message_tools;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../core/bubble_ink.dart';
import '../../core/prefs_store.dart';
import '../../models/message.dart';
import '../../theme.dart';

// ── Swipe to reply ──────────────────────────────────────────────────
/// Drag a message to the right to reply to it (like WhatsApp).
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final bool enabled;
  const SwipeToReply({super.key, required this.child, required this.onReply, this.enabled = true});

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> with SingleTickerProviderStateMixin {
  static const _trigger = 56.0;
  static const _max = 76.0;
  double _dx = 0;
  bool _armed = false;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(() => setState(() => _dx = _from * (1 - _back.value)));
  double _from = 0;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    final next = (_dx + d.delta.dx).clamp(0.0, _max);
    if (!_armed && next >= _trigger) HapticFeedback.selectionClick();
    setState(() {
      _dx = next;
      _armed = next >= _trigger;
    });
  }

  void _end([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return GestureDetector(
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_dx > 4)
            Positioned(
              left: 8,
              child: Opacity(
                opacity: (_dx / _trigger).clamp(0.0, 1.0),
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: Colors.black26,
                  child: Icon(Icons.reply_rounded, size: 18, color: _armed ? Colors.white : Colors.white70),
                ),
              ),
            ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}

// ── Message info ────────────────────────────────────────────────────
String _when(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '—';
  final now = DateTime.now();
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final time = '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
  final today = d.year == now.year && d.month == now.month && d.day == now.day;
  final yesterday = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays == 1;
  if (today) return 'Today, $time';
  if (yesterday) return 'Yesterday, $time';
  return '${d.day}/${d.month}/${d.year}, $time';
}

/// When my message was sent, delivered and read — for each person in a group.
Future<void> showMessageInfo(BuildContext context, ApiClient api, ChatMessage m, {required bool isGroup}) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: FutureBuilder<Map<String, dynamic>>(
        future: api.getJson('/api/messages/${m.id}/info'),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Message info needs a connection.', style: TextStyle(color: VeyonColors.muted)),
            );
          }
          if (!snap.hasData) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
          final info = snap.data!;
          final people = (info['recipients'] as List<dynamic>).cast<Map<String, dynamic>>();
          final hidden = info['readsHidden'] == true;
          Widget row(IconData icon, Color color, String label, String? at) => ListTile(
                dense: true,
                leading: Icon(icon, color: color),
                title: Text(label),
                trailing: Text(_when(at), style: const TextStyle(color: VeyonColors.muted)),
              );
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('Message info', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(m.preview, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: VeyonColors.muted)),
                ),
                row(Icons.schedule_rounded, VeyonColors.muted, 'Sent', info['sentAt'] as String?),
                const Divider(),
                if (!isGroup && people.isNotEmpty) ...[
                  row(Icons.done_all_rounded, const Color(0xFF7CC4FF), 'Read', people.first['readAt'] as String?),
                  row(Icons.done_all_rounded, VeyonColors.muted, 'Delivered', people.first['deliveredAt'] as String?),
                ],
                if (isGroup) ...[
                  for (final p in people)
                    ListTile(
                      dense: true,
                      title: Text('${p['name']}'),
                      subtitle: Text(p['readAt'] != null
                          ? 'Read ${_when(p['readAt'] as String?)}'
                          : p['deliveredAt'] != null
                              ? 'Delivered ${_when(p['deliveredAt'] as String?)}'
                              : 'Not delivered yet'),
                      leading: Icon(p['readAt'] != null ? Icons.done_all_rounded : p['deliveredAt'] != null ? Icons.done_all_rounded : Icons.done_rounded,
                          color: p['readAt'] != null ? const Color(0xFF7CC4FF) : VeyonColors.muted),
                    ),
                ],
                if (hidden)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Text('Read receipts are turned off in this chat, so read times aren’t shown.',
                        style: TextStyle(color: VeyonColors.muted, fontSize: 12.5)),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

// ── Link previews ───────────────────────────────────────────────────
final RegExp _firstUrl = RegExp(r'https?:\/\/[^\s<]+[^\s<.,;:!?\)\]\}"' "'" r']', caseSensitive: false);

String? firstLink(String? text) => text == null ? null : _firstUrl.firstMatch(text)?.group(0);

class _Preview {
  final String url;
  final String? title;
  final String? description;
  final String? image;
  final String site;
  const _Preview(this.url, this.title, this.description, this.image, this.site);
}

/// Previews already fetched (null = the page had nothing to show).
final Map<String, Future<_Preview?>> _previewCache = {};

/// The phone fetches the page itself — nothing goes through our server.
Future<_Preview?> _fetchPreview(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return null;
  try {
    final res = await Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 6),
      responseType: ResponseType.bytes,
      followRedirects: true,
      maxRedirects: 4,
      headers: {'user-agent': 'Mozilla/5.0 (Linux; Android) VeyonChat LinkPreview', 'accept': 'text/html'},
      validateStatus: (s) => s != null && s < 400,
    )).get<List<int>>(url);
    final type = res.headers.value('content-type') ?? '';
    if (!type.contains('html')) return null;
    final bytes = res.data ?? const <int>[];
    final html = utf8.decode(bytes.length > 300000 ? bytes.sublist(0, 300000) : bytes, allowMalformed: true);
    String? meta(String name) {
      final re = RegExp('<meta[^>]+(?:property|name)=["\']$name["\'][^>]*>', caseSensitive: false);
      final tag = re.firstMatch(html)?.group(0);
      final content = tag == null ? null : RegExp('content=["\']([^"\']*)["\']', caseSensitive: false).firstMatch(tag)?.group(1);
      return content == null || content.trim().isEmpty ? null : _unescape(content.trim());
    }

    final title = meta('og:title') ?? meta('twitter:title') ??
        RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false).firstMatch(html)?.group(1)?.trim();
    final description = meta('og:description') ?? meta('description') ?? meta('twitter:description');
    var image = meta('og:image') ?? meta('twitter:image');
    if (image != null) image = uri.resolve(image).toString();
    if (title == null && description == null) return null;
    return _Preview(url, title == null ? null : _unescape(title), description, image, uri.host.replaceFirst('www.', ''));
  } catch (_) {
    return null;
  }
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

/// A small card under a message with a link: picture, title, site.
class LinkPreviewCard extends StatelessWidget {
  final String url;
  const LinkPreviewCard({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Preview?>(
      future: _previewCache.putIfAbsent(url, () => _fetchPreview(url)),
      builder: (context, snap) {
        final p = snap.data;
        if (p == null) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () => launchUrl(Uri.parse(p.url), mode: LaunchMode.externalApplication),
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.image != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: Image.network(p.image!, fit: BoxFit.cover, width: double.infinity,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (p.title != null)
                        Text(p.title!, maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: BubbleInk.of(context), fontWeight: FontWeight.w700, fontSize: 13.5)),
                      if (p.description != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(p.description!, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: BubbleInk.dim(context), fontSize: 12.5)),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(p.site, style: TextStyle(color: BubbleInk.dim(context), fontSize: 11.5)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Text size ───────────────────────────────────────────────────────
const chatTextSizes = [
  ('small', 'Small', 0.9),
  ('medium', 'Medium', 1.0),
  ('large', 'Large', 1.15),
  ('xlarge', 'Extra large', 1.3),
];

String get chatTextSize => (PrefsStore.instance.get('chatTextSize') as String?) ?? 'medium';

double get chatTextScale => chatTextSizes.firstWhere((s) => s.$1 == chatTextSize, orElse: () => chatTextSizes[1]).$3;

Future<void> pickChatTextSize(BuildContext context) async {
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Chat text size'),
      children: [
        for (final (key, label, scale) in chatTextSizes)
          ListTile(
            leading: Icon(key == chatTextSize ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            title: Text(label, style: TextStyle(fontSize: 15 * scale)),
            onTap: () => Navigator.pop(ctx, key),
          ),
      ],
    ),
  );
  if (picked != null) PrefsStore.instance.put('chatTextSize', picked);
}
