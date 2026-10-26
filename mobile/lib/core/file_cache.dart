/// On-device cache for decrypted attachment bytes, keyed by message id --
/// so a photo/file only ever needs to be downloaded+decrypted once, and
/// stays viewable offline afterwards (same rationale as local_cache.dart's
/// message-text cache).
library file_cache;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class FileCache {
  Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    final filesDir = Directory('${dir.path}/veyon_cache/files');
    if (!await filesDir.exists()) await filesDir.create(recursive: true);
    return filesDir;
  }

  Future<File> _fileFor(String messageId) async {
    final dir = await _dir();
    return File('${dir.path}/$messageId.bin');
  }

  Future<Uint8List?> load(String messageId) async {
    try {
      final file = await _fileFor(messageId);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String messageId, Uint8List bytes) async {
    try {
      final file = await _fileFor(messageId);
      await file.writeAsBytes(bytes);
    } catch (_) {
      // Best-effort -- a failed cache write just means re-downloading next time.
    }
  }
}
