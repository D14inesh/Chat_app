/// Business tools on the phone: product catalogue (manage, browse, send in a
/// chat), product + automatic-reply bubbles, away message, private notes.
library shop;

import 'package:veyon_chat_mobile/core/bubble_ink.dart';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../core/api_client.dart';
import '../../core/crypto/keys.dart';
import '../../models/conversation.dart';
import '../../models/message.dart';
import '../../theme.dart';
import '../auth/session.dart';
import '../groups/group_tools.dart';

String priceText(num? price, String currency) {
  if (price == null) return '';
  try {
    return NumberFormat.simpleCurrency(name: currency, decimalDigits: price % 1 == 0 ? 0 : 2).format(price);
  } catch (_) {
    return '$currency $price';
  }
}

/// A server image that needs the signed-in cookie (catalogue photos).
class ApiImage extends ConsumerStatefulWidget {
  final String url;
  final BoxFit fit;
  const ApiImage(this.url, {super.key, this.fit = BoxFit.cover});
  @override
  ConsumerState<ApiImage> createState() => _ApiImageState();
}

class _ApiImageState extends ConsumerState<ApiImage> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _cache[widget.url];
    if (_bytes == null) {
      ref.read(sessionControllerProvider).api.fetchBytes(widget.url).then((b) {
        final bytes = Uint8List.fromList(b);
        _cache[widget.url] = bytes;
        if (mounted) setState(() => _bytes = bytes);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) => _bytes == null
      ? Container(color: VeyonColors.hairline, child: const Center(child: Icon(Icons.image_outlined, color: VeyonColors.line)))
      : Image.memory(_bytes!, fit: widget.fit, gaplessPlayback: true);
}

Widget _noPhoto([double size = 34]) => Container(
      color: VeyonColors.hairline,
      child: Center(child: Icon(Icons.shopping_bag_outlined, size: size, color: VeyonColors.muted)),
    );

// ── Bubbles ─────────────────────────────────────────────────

class ProductBubble extends ConsumerWidget {
  final ChatMessage message;
  final bool mine;
  const ProductBubble({super.key, required this.message, required this.mine});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = message.payload ?? const {};
    final photo = p['photoUrl'] as String?;
    final seller = p['sellerId'] as String?;
    return SizedBox(
      width: 240,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: Colors.black.withValues(alpha: 0.16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(aspectRatio: 4 / 3, child: photo != null ? ApiImage(photo) : _noPhoto()),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['name'] as String? ?? 'Product', style: TextStyle(color: BubbleInk.of(context), fontWeight: FontWeight.w800, fontSize: 14.5)),
                if (p['price'] != null)
                  Text(priceText(p['price'] as num, p['currency'] as String? ?? 'INR'),
                      style: TextStyle(color: mine ? BubbleInk.of(context) : VeyonColors.online, fontWeight: FontWeight.w800)),
                if ((p['description'] as String? ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(p['description'] as String, maxLines: 3, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: BubbleInk.dim(context), fontSize: 12.5)),
                  ),
                if (seller != null) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(backgroundColor: BubbleInk.of(context).withValues(alpha: 0.12), foregroundColor: BubbleInk.of(context), visualDensity: VisualDensity.compact),
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CatalogueScreen(userId: seller))),
                      child: const Text('View catalogue'),
                    ),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class AutoReplyBody extends StatelessWidget {
  final String text;
  const AutoReplyBody({super.key, required this.text});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.schedule_rounded, size: 12, color: BubbleInk.dim(context)),
          const SizedBox(width: 4),
          Text('AUTOMATIC REPLY', style: TextStyle(color: BubbleInk.dim(context), fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
        ]),
        const SizedBox(height: 3),
        Text(text, style: TextStyle(color: BubbleInk.of(context), fontSize: 14.5)),
      ]);
}

Map<String, dynamic> productSnapshot(Map<String, dynamic> it) => {
      'itemId': it['id'],
      'sellerId': it['sellerId'],
      'name': it['name'],
      'price': it['price'],
      'currency': it['currency'],
      'description': it['description'],
      'photoUrl': it['photoUrl'],
    };

// ── Browse a catalogue ──────────────────────────────────────

class CatalogueScreen extends ConsumerStatefulWidget {
  final String userId;
  final String? name;
  /// Picking a product sends it here (my own catalogue, from the attach menu).
  final void Function(Map<String, dynamic> snapshot)? onPick;
  const CatalogueScreen({super.key, required this.userId, this.name, this.onPick});
  @override
  ConsumerState<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends ConsumerState<CatalogueScreen> {
  List<Map<String, dynamic>>? _items;
  String? _error;
  String? _name;

  @override
  void initState() {
    super.initState();
    _name = widget.name;
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(sessionControllerProvider).api;
    try {
      final r = await api.getJson('/api/users/${widget.userId}/catalog');
      if (_name == null) {
        try {
          _name = (await api.getUser(widget.userId))['displayName'] as String?;
        } catch (_) {}
      }
      if (mounted) setState(() => _items = (r['items'] as List).cast<Map<String, dynamic>>());
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load the catalogue — check your connection.');
    }
  }

  bool get _mine => widget.userId == ref.read(sessionControllerProvider).user?.id;

  void _open(Map<String, dynamic> it) {
    if (widget.onPick != null) {
      widget.onPick!(productSnapshot(it));
      Navigator.pop(context);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (it['photoUrl'] != null)
              ClipRRect(borderRadius: BorderRadius.circular(14), child: AspectRatio(aspectRatio: 4 / 3, child: ApiImage(it['photoUrl'] as String))),
            const SizedBox(height: 12),
            Text(it['name'] as String, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            if (it['price'] != null)
              Text(priceText(it['price'] as num, it['currency'] as String),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: VeyonColors.online)),
            if ((it['description'] as String).isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(it['description'] as String, style: const TextStyle(color: VeyonColors.muted, height: 1.45))),
            const SizedBox(height: 16),
            if (!_mine)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: Text('Ask ${_name ?? 'them'} about this'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    ref.read(pendingProductProvider.notifier).state = productSnapshot(it);
                    await openDirectWith(context, ref, widget.userId);
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.onPick != null ? 'Send a product' : _mine ? 'My catalogue' : '${_name ?? 'Business'} · Catalogue'),
        actions: [
          if (_mine && widget.onPick == null)
            TextButton(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CatalogManagerScreen()));
                _load();
              },
              child: const Text('Manage'),
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? const Center(child: Text('No products yet.', style: TextStyle(color: VeyonColors.muted)))
                  : GridView.count(
                      crossAxisCount: 2,
                      padding: const EdgeInsets.all(12),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.78,
                      children: [
                        for (final it in items.where((i) => widget.onPick == null || i['available'] == true))
                          InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => _open(it),
                            child: Opacity(
                              opacity: it['available'] == true ? 1 : 0.55,
                              child: Container(
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(14)),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Expanded(child: SizedBox(width: double.infinity, child: it['photoUrl'] != null ? ApiImage(it['photoUrl'] as String) : _noPhoto())),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(it['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                                      Text(
                                        '${priceText(it['price'] as num?, it['currency'] as String)}${it['available'] == true ? '' : ' · hidden'}',
                                        style: const TextStyle(color: VeyonColors.online, fontWeight: FontWeight.w700, fontSize: 12.5),
                                      ),
                                    ]),
                                  ),
                                ]),
                              ),
                            ),
                          ),
                      ],
                    ),
    );
  }
}

/// A product chosen with "Ask about this", sent when that chat opens.
final pendingProductProvider = StateProvider<Map<String, dynamic>?>((ref) => null);

// ── Manage my catalogue ─────────────────────────────────────

class CatalogManagerScreen extends ConsumerStatefulWidget {
  const CatalogManagerScreen({super.key});
  @override
  ConsumerState<CatalogManagerScreen> createState() => _CatalogManagerScreenState();
}

class _CatalogManagerScreenState extends ConsumerState<CatalogManagerScreen> {
  List<Map<String, dynamic>>? _items;

  ApiClient get _api => ref.read(sessionControllerProvider).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = ref.read(sessionControllerProvider).user!.id;
    try {
      final r = await _api.getJson('/api/users/$me/catalog');
      if (mounted) setState(() => _items = (r['items'] as List).cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  Future<void> _move(int i, int j) async {
    final items = _items!;
    final t = items[i];
    items[i] = items[j];
    items[j] = t;
    setState(() {});
    await _api.postJson('/api/catalog/reorder', {'ids': items.map((x) => x['id']).toList()}).catchError((_) => <String, dynamic>{});
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('My catalogue')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add product'),
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProductEditorScreen()));
          _load();
        },
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No products yet.\nAdd what you sell — customers see it on your profile and you can send it in chats.',
                        textAlign: TextAlign.center, style: TextStyle(color: VeyonColors.muted)),
                  ),
                )
              : ListView(padding: const EdgeInsets.fromLTRB(10, 10, 10, 90), children: [
                  for (var i = 0; i < items.length; i++)
                    Card(
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: items[i]['photoUrl'] != null ? ApiImage(items[i]['photoUrl'] as String) : _noPhoto(20),
                          ),
                        ),
                        title: Text(items[i]['name'] as String),
                        subtitle: Text(
                          '${priceText(items[i]['price'] as num?, items[i]['currency'] as String)}${items[i]['available'] == true ? '' : ' · hidden'}',
                          style: const TextStyle(color: VeyonColors.online),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (a) async {
                            if (a == 'up') return _move(i, i - 1);
                            if (a == 'down') return _move(i, i + 1);
                            if (a == 'edit') {
                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductEditorScreen(item: items[i])));
                            } else {
                              await _api.deleteJson('/api/catalog/${items[i]['id']}').catchError((_) => <String, dynamic>{});
                            }
                            _load();
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'edit', child: Text('Edit')),
                            if (i > 0) const PopupMenuItem(value: 'up', child: Text('Move up')),
                            if (i < items.length - 1) const PopupMenuItem(value: 'down', child: Text('Move down')),
                            const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: VeyonColors.danger))),
                          ],
                        ),
                      ),
                    ),
                ]),
    );
  }
}

class ProductEditorScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic>? item;
  const ProductEditorScreen({super.key, this.item});
  @override
  ConsumerState<ProductEditorScreen> createState() => _ProductEditorScreenState();
}

class _ProductEditorScreenState extends ConsumerState<ProductEditorScreen> {
  static const _currencies = ['INR', 'USD', 'EUR', 'GBP', 'AED', 'SGD', 'MYR', 'LKR'];
  late final _name = TextEditingController(text: widget.item?['name'] as String? ?? '');
  late final _price = TextEditingController(text: widget.item?['price']?.toString() ?? '');
  late final _desc = TextEditingController(text: widget.item?['description'] as String? ?? '');
  late String _currency = widget.item?['currency'] as String? ?? 'INR';
  late bool _available = widget.item?['available'] as bool? ?? true;
  Uint8List? _photo;
  String _photoMime = 'image/jpeg';
  bool _removePhoto = false;
  bool _saving = false;

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final f = r?.files.singleOrNull;
    if (f?.bytes == null) return;
    setState(() {
      _photo = f!.bytes;
      _photoMime = lookupMimeType(f.name) ?? 'image/jpeg';
      _removePhoto = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final api = ref.read(sessionControllerProvider).api;
      final fields = {
        'name': _name.text,
        'price': _price.text,
        'currency': _currency,
        'description': _desc.text,
        'available': _available ? 'true' : 'false',
        if (widget.item != null) 'remove_photo': _removePhoto ? 'true' : 'false',
      };
      if (widget.item == null) {
        await api.sendForm('POST', '/api/catalog', fields, photo: _photo, photoMime: _photoMime);
      } else {
        await api.sendForm('PATCH', '/api/catalog/${widget.item!['id']}', fields, photo: _photo, photoMime: _photoMime);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errText(e))));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.item?['photoUrl'] as String?;
    final accent = Theme.of(context).colorScheme.secondary;
    return Scaffold(
      appBar: AppBar(title: Text(widget.item == null ? 'Add product' : 'Edit product'), actions: [
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        InkWell(
          onTap: _pick,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 180,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: accent.withValues(alpha: 0.5), width: 1.5),
              color: accent.withValues(alpha: 0.06),
            ),
            child: _photo != null
                ? Image.memory(_photo!, fit: BoxFit.cover, width: double.infinity)
                : existing != null && !_removePhoto
                    ? SizedBox(width: double.infinity, child: ApiImage(existing))
                    : Center(
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.add_a_photo_rounded, color: accent),
                          const SizedBox(width: 8),
                          Text('Add a photo', style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
                        ]),
                      ),
          ),
        ),
        if (_photo != null || (existing != null && !_removePhoto))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() {
                _photo = null;
                _removePhoto = true;
              }),
              child: const Text('Remove photo'),
            ),
          ),
        const SizedBox(height: 12),
        TextField(controller: _name, maxLength: 80, decoration: const InputDecoration(labelText: 'Name', counterText: '')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Price'),
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _currency,
            items: [for (final c in _currencies) DropdownMenuItem(value: c, child: Text(c))],
            onChanged: (v) => setState(() => _currency = v!),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _desc, maxLength: 600, maxLines: 4, minLines: 2, decoration: const InputDecoration(labelText: 'Description')),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _available,
          onChanged: (v) => setState(() => _available = v),
          title: const Text('Show in catalogue'),
          subtitle: const Text('Turn off to hide it without deleting', style: TextStyle(color: VeyonColors.muted)),
        ),
      ]),
    );
  }
}

// ── Away message ────────────────────────────────────────────

class AwaySettingsScreen extends ConsumerStatefulWidget {
  const AwaySettingsScreen({super.key});
  @override
  ConsumerState<AwaySettingsScreen> createState() => _AwaySettingsScreenState();
}

class _AwaySettingsScreenState extends ConsumerState<AwaySettingsScreen> {
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final _msg = TextEditingController();
  bool _loaded = false;
  bool _enabled = false;
  String _mode = 'outside';
  TimeOfDay _from = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _to = const TimeOfDay(hour: 18, minute: 0);
  Set<int> _openDays = {1, 2, 3, 4, 5, 6};

  @override
  void initState() {
    super.initState();
    ref.read(sessionControllerProvider).api.getJson('/api/users/me/away').then((r) {
      final a = r['away'] as Map<String, dynamic>;
      TimeOfDay t(String s) => TimeOfDay(hour: int.parse(s.split(':')[0]), minute: int.parse(s.split(':')[1]));
      if (!mounted) return;
      setState(() {
        _enabled = a['enabled'] == true;
        _msg.text = a['message'] as String? ?? '';
        _mode = a['mode'] == 'always' ? 'always' : 'outside';
        _from = t(a['from'] as String? ?? '09:00');
        _to = t(a['to'] as String? ?? '18:00');
        _openDays = {for (final d in (a['days'] as List? ?? const [])) (d as num).toInt()};
        _loaded = true;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    try {
      await ref.read(sessionControllerProvider).api.patchJson('/api/users/me/away', {
        'enabled': _enabled,
        'message': _msg.text,
        'mode': _mode,
        'from': _hm(_from),
        'to': _hm(_to),
        'days': _openDays.toList(),
        'tzOffset': DateTime.now().timeZoneOffset.inMinutes,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Away message saved.')));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Away message'), actions: [
        Padding(padding: const EdgeInsets.only(right: 10), child: FilledButton(onPressed: _loaded ? _save : null, child: const Text('Save'))),
      ]),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(18), children: [
              const Text('Customers who message you while you’re away get this reply automatically — at most once every 12 hours each.',
                  style: TextStyle(color: VeyonColors.muted)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
                title: const Text('Send away message'),
              ),
              TextField(controller: _msg, maxLength: 500, maxLines: 4, minLines: 3, decoration: const InputDecoration(labelText: 'Message')),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'outside', label: Text('Outside hours')),
                  ButtonSegment(value: 'always', label: Text('Always')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              if (_mode == 'outside') ...[
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final t = await showTimePicker(context: context, initialTime: _from);
                        if (t != null) setState(() => _from = t);
                      },
                      child: Text('Open ${_from.format(context)}'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final t = await showTimePicker(context: context, initialTime: _to);
                        if (t != null) setState(() => _to = t);
                      },
                      child: Text('Close ${_to.format(context)}'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                const Text('Open on', style: TextStyle(color: VeyonColors.muted, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (var i = 0; i < 7; i++)
                    FilterChip(
                      label: Text(_days[i]),
                      selected: _openDays.contains(i + 1),
                      onSelected: (v) => setState(() => v ? _openDays.add(i + 1) : _openDays.remove(i + 1)),
                    ),
                ]),
              ],
            ]),
    );
  }
}

// ── Private notes on a chat ─────────────────────────────────

Future<void> showChatNotes(BuildContext context, WidgetRef ref, Conversation c, SecretKey? key) async {
  if (key == null) return;
  final api = ref.read(sessionControllerProvider).api;
  var text = '';
  try {
    final note = (await api.getJson('/api/conversations/${c.id}/note'))['note'] as Map<String, dynamic>?;
    if (note != null) text = await decryptText(key, note['ciphertext'] as String, note['iv'] as String);
  } catch (_) {}
  if (!context.mounted) return;
  final ctrl = TextEditingController(text: text);
  final isBiz = ref.read(sessionControllerProvider).user?.businessSettings?['enabled'] == true;
  final save = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, MediaQuery.of(ctx).viewInsets.bottom + 18),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${isBiz ? 'Customer notes' : 'Notes'} · ${c.displayName('Chat')}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Only you can see these — they’re encrypted like your messages.', style: TextStyle(color: VeyonColors.muted)),
        const SizedBox(height: 12),
        TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 8,
          minLines: 5,
          maxLength: 5000,
          decoration: InputDecoration(hintText: isBiz ? 'Order details, preferences, follow-ups…' : 'Anything to remember about this chat'),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ]),
      ]),
    ),
  );
  if (save != true) return;
  try {
    final value = ctrl.text.trim();
    if (value.isEmpty) {
      await api.putJson('/api/conversations/${c.id}/note', {'ciphertext': ''});
    } else {
      final env = await encryptText(key, value);
      await api.putJson('/api/conversations/${c.id}/note', {'ciphertext': env.ciphertext, 'iv': env.iv});
    }
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value.isEmpty ? 'Note cleared.' : 'Note saved.')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errText(e))));
  }
}
