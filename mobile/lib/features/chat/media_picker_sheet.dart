/// Emoji / Stickers / GIF picker — the mobile version of the website's
/// composer media picker (same emoji groups, sticker set and "recent" list).
///   · Emoji: tapping inserts into the message box
///   · Sticker: sent immediately as a big single-emoji message
///   · GIF: Tenor search through the backend, sent as an encrypted image
library media_picker_sheet;

import '../../theme.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api_client.dart';
import 'chat3_tools.dart';

const _emojiGroups = <String, List<String>>{
  'Smileys': ['😀','😃','😄','😁','😆','😅','🤣','😂','🙂','🙃','😉','😊','😇','🥰','😍','🤩','😘','😗','😚','😙','😋','😛','😜','🤪','😝','🤑','🤗','🤭','🤫','🤔','🤐','🤨','😐','😑','😶','😏','😒','🙄','😬','🤥','😌','😔','😪','🤤','😴','😷','🤒','🤕','🤢','🤮','🥵','🥶','😵','🤯','🤠','🥳','😎','🤓','🧐','😕','😟','🙁','😮','😯','😲','😳','🥺','😦','😧','😨','😰','😥','😢','😭','😱','😖','😣','😞','😓','😩','😫','🥱','😤','😡','😠','🤬','😈','👿','💀','💩','🤡','👻','👽','🤖'],
  'People': ['👋','🤚','🖐️','✋','🖖','👌','🤌','🤏','✌️','🤞','🤟','🤘','🤙','👈','👉','👆','🖕','👇','☝️','👍','👎','✊','👊','🤛','🤜','👏','🙌','👐','🤲','🤝','🙏','✍️','💅','🤳','💪','🦾','🦿','🦵','🦶','👂','👃','🧠','🫀','🫁','🦷','🦴','👀','👁️','👅','👄','💋','🩸'],
  'Symbols': ['❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💔','❣️','💕','💞','💓','💗','💖','💘','💝','💟','☮️','✝️','☪️','🕉️','☸️','✡️','🔯','🕎','☯️','☦️','🛐','⛎','♈','♉','♊','♋','♌','♍','♎','♏','♐','♑','♒','♓','🆔','⚛️','🉑','☢️','☣️','📴','📳','💯','🔥','✨','🎉','🎊','⭐','🌟','💫','⚡','💥','🌈'],
  'Animals': ['🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷','🐽','🐸','🐵','🙈','🙉','🙊','🐒','🐔','🐧','🐦','🐤','🦆','🦅','🦉','🦇','🐺','🐗','🐴','🦄','🐝','🐛','🦋','🐌','🐞','🐜','🦂','🐢','🐍','🦎','🐙','🦑','🦀','🐡','🐠','🐟','🐬','🐳','🐋','🦈','🐊','🐅','🐆','🦓','🦍','🐘','🦛','🦏','🐪','🐫','🦒','🦘','🐃','🐂','🐄','🐎','🐖','🐏','🐑','🐐','🦌','🐕','🐩','🐈','🐓','🦃','🕊️','🐇','🐁','🐀','🐿️','🦔'],
  'Food': ['🍏','🍎','🍐','🍊','🍋','🍌','🍉','🍇','🍓','🫐','🍈','🍒','🍑','🥭','🍍','🥥','🥝','🍅','🍆','🥑','🥦','🥬','🥒','🌶️','🌽','🥕','🧄','🧅','🥔','🍠','🥐','🥯','🍞','🥖','🥨','🧀','🥚','🍳','🧈','🥞','🧇','🥓','🥩','🍗','🍖','🌭','🍔','🍟','🍕','🥪','🥙','🧆','🌮','🌯','🥗','🥘','🍝','🍜','🍲','🍛','🍣','🍱','🥟','🍤','🍚','🍘','🍥','🥮','🍢','🍡','🍧','🍨','🍦','🥧','🧁','🍰','🎂','🍮','🍭','🍬','🍫','🍿','🍩','🍪','☕','🍵','🧋','🥤','🍶','🍺','🍷','🥂','🥃','🍸','🍹','🍾'],
  'Activities': ['⚽','🏀','🏈','⚾','🥎','🎾','🏐','🏉','🥏','🎱','🪀','🏓','🏸','🏒','🏑','🥍','🏏','🥅','⛳','🪁','🏹','🎣','🤿','🥊','🥋','🎽','🛹','🛷','⛸️','🥌','🎿','⛷️','🏂','🏋️','🤼','🤸','⛹️','🤺','🤾','🏌️','🏇','🧘','🏄','🏊','🤽','🚣','🧗','🚵','🚴','🏆','🥇','🥈','🥉','🏅','🎖️','🎗️','🎫','🎟️','🎪','🎭','🩰','🎨','🎬','🎤','🎧','🎼','🎹','🥁','🎷','🎺','🎸','🪕','🎻','🎲','♟️','🎯','🎳','🎮','🎰','🧩'],
  'Travel': ['🚗','🚕','🚙','🚌','🚎','🏎️','🚓','🚑','🚒','🚐','🚚','🚛','🚜','🛴','🚲','🛵','🏍️','🛺','🚨','🚔','🚍','🚘','🚖','🚡','🚠','🚟','🚃','🚋','🚞','🚝','🚄','🚅','🚈','🚂','🚆','🚇','🚊','🚉','✈️','🛫','🛬','🛩️','💺','🛰️','🚀','🛸','🚁','🛶','⛵','🚤','🛥️','🛳️','⛴️','🚢','⚓','⛽','🚧','🚦','🚥','🗺️','🗿','🗽','🗼','🏰','🏯','🏟️','🎡','🎢','🎠','⛲','⛱️','🏖️','🏝️','🏜️','🌋','⛰️','🏔️','🗻','🏕️','⛺','🏠','🏡','🏘️','🏚️','🏗️','🏢','🏬','🏣','🏤','🏥','🏦','🏨','🏪','🏫','🏩','💒','🏛️','⛪','🕌','🕍','🛕','🕋','⛩️','🌁','🌃','🏙️','🌄','🌅','🌆','🌇','🌉'],
  'Objects': ['⌚','📱','📲','💻','⌨️','🖥️','🖨️','🖱️','🖲️','🕹️','🗜️','💽','💾','💿','📀','📼','📷','📸','📹','🎥','📽️','🎞️','📞','☎️','📟','📠','📺','📻','🎙️','🎚️','🎛️','🧭','⏱️','⏲️','⏰','🕰️','⌛','⏳','📡','🔋','🔌','💡','🔦','🕯️','🪔','🧯','🛢️','💸','💵','💴','💶','💷','💰','💳','💎','⚖️','🧰','🔧','🔨','⚒️','🛠️','⛏️','🔩','⚙️','🧱','⛓️','🧲','🔫','💣','🧨','🪓','🔪','🗡️','⚔️','🛡️','🚬','⚰️','⚱️','🏺','🔮','📿','🧿','💈','⚗️','🔭','🔬','🕳️','🩹','🩺','💊','💉','🩸','🧬','🦠','🧫','🧪','🌡️','🧹','🧺','🧻','🚽','🚰','🚿','🛁','🛀','🧼','🪒','🧽','🧴','🛎️','🔑','🗝️','🚪','🪑','🛋️','🛏️','🛌','🧸','🖼️','🛍️','🛒','🎁','🎈','🎏','🎀','🎊','🎉','🎎','🏮','🎐','🧧','✉️','📩','📨','📧','💌','📥','📤','📦','🏷️','📪','📫','📬','📭','📮','📯','📜','📃','📄','📑','📊','📈','📉','🗒️','🗓️','📆','📅','📇','🗃️','🗳️','🗄️','📋','📁','📂','🗂️','🗞️','📰','📓','📔','📒','📕','📗','📘','📙','📚','📖','🔖','🧷','🔗','📎','🖇️','📐','📏','🧮','📌','📍','✂️','🖊️','🖋️','✒️','🖌️','🖍️','📝','✏️','🔍','🔎'],
};

const _categoryIcons = {
  'Recent': '🕐', 'Smileys': '😀', 'People': '👋', 'Symbols': '❤️', 'Animals': '🐶',
  'Food': '🍎', 'Activities': '⚽', 'Travel': '🚗', 'Objects': '💡',
};

/// Big, fun single glyphs — sent as a message and rendered jumbo (no bubble).
const kStickerSet = ['😂','🥹','😍','🥰','😎','🤩','🥳','😭','😅','🤔','😴','🤯','🫡','🫠','🙄','😤','🤗','🫶','👍','👎','👏','🙏','🔥','💯','🎉','✨','💖','💔','⭐','⚡','🌈','🍕','☕','🎂','🏆','⚽','🚀','💀','👻','🤖','👽','🐶','🐱','🦄','🐢','🦋','🌸','🌊','🌙','☀️','❄️'];

/// The six quick reactions on every message — same as the website.
const kReactionEmoji = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Recently used emoji, newest first (max 40), kept on the phone.
class RecentEmoji {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/recent_emoji.json');
  }

  static Future<List<String>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      return (jsonDecode(await f.readAsString()) as List<dynamic>).cast<String>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> push(String emoji) async {
    final list = (await load())..remove(emoji)..insert(0, emoji);
    try {
      await (await _file()).writeAsString(jsonEncode(list.take(40).toList()));
    } catch (_) {}
  }
}

class MediaPickerSheet extends StatefulWidget {
  final ApiClient api;
  final ValueChanged<String> onEmoji;
  final ValueChanged<String> onSticker;
  final ValueChanged<String> onGif; // Tenor URL
  /// Stickers made from photos: "Create" and the saved ones (PNG bytes).
  final VoidCallback? onMakeSticker;
  final ValueChanged<Uint8List>? onMySticker;
  const MediaPickerSheet({
    super.key,
    required this.api,
    required this.onEmoji,
    required this.onSticker,
    required this.onGif,
    this.onMakeSticker,
    this.onMySticker,
  });

  @override
  State<MediaPickerSheet> createState() => _MediaPickerSheetState();
}

class _MediaPickerSheetState extends State<MediaPickerSheet> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  String _category = 'Smileys';
  List<String> _recent = [];

  bool? _gifEnabled;
  List<dynamic> _gifs = [];
  bool _gifLoading = false;
  String? _gifError;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    RecentEmoji.load().then((r) => mounted ? setState(() => _recent = r) : null);
    _tabs.addListener(() {
      if (_tabs.index == 2 && _gifEnabled == null) _initGifs();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _initGifs() async {
    try {
      final enabled = await widget.api.gifEnabled();
      if (!mounted) return;
      setState(() => _gifEnabled = enabled);
      if (enabled) _searchGifs('');
    } catch (_) {
      if (mounted) setState(() { _gifEnabled = true; _gifError = 'GIFs need a connection.'; });
    }
  }

  Future<void> _searchGifs(String q) async {
    setState(() { _gifLoading = true; _gifError = null; });
    try {
      final results = await widget.api.searchGifs(q.trim());
      if (mounted) setState(() { _gifs = results; _gifLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _gifError = 'Could not load GIFs — check your connection.'; _gifLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.45,
        child: Column(
          children: [
            TabBar(controller: _tabs, tabs: const [Tab(text: 'Emoji'), Tab(text: 'Stickers'), Tab(text: 'GIF')]),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [_emojiTab(), _stickerTab(), _gifTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emojiTab() {
    final list = _category == 'Recent' ? _recent : _emojiGroups[_category]!;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final entry in _categoryIcons.entries)
                InkWell(
                  onTap: () => setState(() => _category = entry.key),
                  child: Container(
                    width: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: _category == entry.key ? Colors.white : Colors.transparent, width: 2)),
                    ),
                    child: Text(entry.value, style: const TextStyle(fontSize: 20)),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('No recent emoji yet.', style: TextStyle(color: VeyonColors.muted)))
              : GridView.count(
                  crossAxisCount: 8,
                  children: [
                    for (final e in list)
                      InkWell(
                        onTap: () {
                          widget.onEmoji(e);
                          RecentEmoji.push(e);
                        },
                        child: Center(child: Text(e, style: const TextStyle(fontSize: 26))),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _stickerTab() {
    final accent = Theme.of(context).colorScheme.secondary;
    return CustomScrollView(slivers: [
      if (widget.onMakeSticker != null) ...[
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text('MY STICKERS', style: TextStyle(color: VeyonColors.muted, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
          ),
        ),
        SliverToBoxAdapter(
          child: FutureBuilder<List<File>>(
            future: myStickers(),
            builder: (ctx, snap) => GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 4,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    Navigator.pop(context);
                    widget.onMakeSticker!();
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accent.withValues(alpha: 0.5), width: 1.5),
                      color: accent.withValues(alpha: 0.08),
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.add_photo_alternate_rounded, color: accent),
                      const SizedBox(height: 4),
                      Text('Create', style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 12)),
                    ]),
                  ),
                ),
                for (final f in snap.data ?? const <File>[])
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () async {
                      final bytes = await f.readAsBytes();
                      if (!mounted) return;
                      Navigator.pop(context);
                      widget.onMySticker?.call(bytes);
                    },
                    onLongPress: () async {
                      await f.delete();
                      setState(() {});
                    },
                    child: Image.file(f, fit: BoxFit.contain),
                  ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 14, 12, 0),
            child: Text('EMOJI STICKERS', style: TextStyle(color: VeyonColors.muted, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
          ),
        ),
      ],
      SliverToBoxAdapter(child: GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 5,
      padding: const EdgeInsets.all(8),
      children: [
        for (final s in kStickerSet)
          InkWell(
            onTap: () {
              RecentEmoji.push(s);
              Navigator.pop(context);
              widget.onSticker(s);
            },
            child: Center(child: Text(s, style: const TextStyle(fontSize: 40))),
          ),
      ],
    )),
    ]);
  }

  Widget _gifTab() {
    if (_gifEnabled == false) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'GIF search needs a free Tenor API key.\nAdd TENOR_API_KEY=… to the backend .env and restart the server.',
            textAlign: TextAlign.center,
            style: TextStyle(color: VeyonColors.muted),
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Search GIFs', prefixIcon: Icon(Icons.search_rounded), isDense: true),
            onChanged: (q) {
              _searchDebounce?.cancel();
              _searchDebounce = Timer(const Duration(milliseconds: 350), () => _searchGifs(q));
            },
          ),
        ),
        Expanded(
          child: _gifLoading || _gifEnabled == null
              ? const Center(child: CircularProgressIndicator())
              : _gifError != null
                  ? Center(child: Text(_gifError!, style: const TextStyle(color: VeyonColors.muted)))
                  : _gifs.isEmpty
                      ? const Center(child: Text('No GIFs found.', style: TextStyle(color: VeyonColors.muted)))
                      : GridView.count(
                          crossAxisCount: 3,
                          padding: const EdgeInsets.all(6),
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                          children: [
                            for (final g in _gifs.cast<Map<String, dynamic>>())
                              InkWell(
                                onTap: () {
                                  Navigator.pop(context);
                                  widget.onGif(g['url'] as String);
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(g['preview'] as String, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
                                ),
                              ),
                          ],
                        ),
        ),
      ],
    );
  }
}
