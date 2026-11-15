/// Helpers for the agent-connected IDE (build #99, part B).
///
/// The chat turns and the file screens share two rules, kept here so they
/// can be unit-tested without a device:
///
/// * the file open in the IDE rides along on a turn as document context,
///   capped like an attached document;
/// * deleting the file that is the remembered active file also clears the
///   remembered path, so nothing keeps pointing at a file that is gone.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'text_utils.dart';

class IdeFile {
  IdeFile._();

  /// Characters of the active file a turn may carry — the same cap as an
  /// attached document.
  static const int maxContextChars = 4000;

  /// The context block for the file open in the IDE, formatted like an
  /// attached document so Cypher can tell it apart from one.
  static String formatContext({
    required String path,
    required String text,
  }) {
    return '\n\nContext from the open file in the IDE:\n'
        '--- ${p.basename(path)} ---\n'
        '${TextUtils.ellipsize(text, maxContextChars)}';
  }

  /// Reads the active file and returns its context block, or null when
  /// there is no active file, it is gone, or it cannot be read as text.
  /// A null result for a non-empty path is the caller's cue to clear the
  /// remembered path.
  static Future<String?> readContext(String? path) async {
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      return formatContext(path: path, text: await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Whether deleting [deletedPath] must also clear the remembered active
  /// file: only when the deleted file IS that file. Deleting any other
  /// file leaves the active file alone.
  static bool clearsActiveFile({
    required String? activePath,
    required String deletedPath,
  }) =>
      activePath != null &&
      activePath.isNotEmpty &&
      activePath == deletedPath;

  /// Deletes [file] from disk. True when the delete succeeded; false when
  /// it failed (missing file, permissions). A failed delete never clears
  /// the active file — the file is still there.
  static Future<bool> deleteFile(File file) async {
    try {
      await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
