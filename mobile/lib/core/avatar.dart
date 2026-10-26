/// Round avatar used everywhere a person or group appears: their profile
/// photo when they have one, coloured initials otherwise, plus an optional
/// green "online" dot — same as the website's avatarInner().
///
/// Photos need the session cookie (they're served by the API), so they're
/// fetched through ApiClient, kept on the phone (shown offline too) and
/// refreshed once per app run in case the person changed theirs.
library avatar;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/session.dart';
import 'file_cache.dart';

final Map<String, Uint8List> _memory = {};
final Set<String> _refreshedThisRun = {};
final Map<String, Future<Uint8List?>> _inFlight = {};

/// Forget a saved photo (its URL stays the same when someone uploads a new
/// one) so the next Avatar fetches it fresh.
Future<void> evictAvatar(String url) async {
  _memory.remove(url);
  _refreshedThisRun.remove(url);
  await FileCache().save('avatar_${url.hashCode.toUnsigned(32)}', Uint8List(0));
}

Color parseHexColor(String? hex, {Color fallback = const Color(0xFF2F6BFF)}) {
  if (hex == null) return fallback;
  final h = hex.replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

class Avatar extends ConsumerStatefulWidget {
  final String label;
  final String? color;
  final String? photoUrl;
  final double radius;
  final bool? online; // null = no dot (groups)

  const Avatar({super.key, required this.label, this.color, this.photoUrl, this.radius = 20, this.online});

  @override
  ConsumerState<Avatar> createState() => _AvatarState();
}

class _AvatarState extends ConsumerState<Avatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant Avatar old) {
    super.didUpdateWidget(old);
    if (old.photoUrl != widget.photoUrl) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.photoUrl;
    if (url == null) return;
    final key = 'avatar_${url.hashCode.toUnsigned(32)}';
    if (_memory[url] != null) {
      setState(() => _bytes = _memory[url]);
    } else {
      final disk = await FileCache().load(key);
      if (disk != null && disk.isNotEmpty && mounted) {
        _memory[url] = disk;
        setState(() => _bytes = disk);
      }
    }
    if (_refreshedThisRun.contains(url)) return;
    final fresh = await (_inFlight[url] ??= _fetch(url, key));
    _inFlight.remove(url);
    if (fresh != null && mounted) setState(() => _bytes = fresh);
  }

  Future<Uint8List?> _fetch(String url, String key) async {
    try {
      final bytes = Uint8List.fromList(await ref.read(sessionControllerProvider).api.fetchBytes(url));
      _memory[url] = bytes;
      _refreshedThisRun.add(url);
      await FileCache().save(key, bytes);
      return bytes;
    } catch (_) {
      return null; // offline — the saved copy (or initials) stays
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.radius;
    final initials = widget.label.trim().isEmpty
        ? '?'
        : widget.label.trim().split(RegExp(r'\s+')).take(2).map((w) => w.characters.first.toUpperCase()).join();
    final circle = CircleAvatar(
      radius: r,
      backgroundColor: parseHexColor(widget.color),
      backgroundImage: _bytes != null ? MemoryImage(_bytes!) : null,
      child: _bytes != null
          ? null
          : Text(initials, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: r * 0.7)),
    );
    if (widget.online == null) return circle;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: r * 0.55,
            height: r * 0.55,
            decoration: BoxDecoration(
              color: widget.online! ? const Color(0xFF2ECC71) : Colors.grey.shade600,
              shape: BoxShape.circle,
              border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}
