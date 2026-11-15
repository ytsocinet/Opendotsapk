/// Tests for the agent-connected IDE helpers (build #99, part B).
///
/// These pin the two rules the chat turns and the file screens share:
/// the file open in the IDE rides along on a turn as document context,
/// capped like an attached document; and deleting the remembered active
/// file clears the remembered path, while deleting any other file — or
/// a delete that fails — leaves it alone. The confirmation dialogs
/// themselves are UI-gated (Cancel never reaches the delete call) and
/// are not covered here: there is no device-level widget test for them.
library;

import 'dart:io';

import 'package:clawzilla/core/utils/ide_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatContext', () {
    test('heads the block with the file name, distinct from attached docs',
        () {
      final out = IdeFile.formatContext(
        path: '/projects/notes.txt',
        text: 'hello',
      );
      expect(out, contains('Context from the open file in the IDE'));
      expect(out, contains('--- notes.txt ---'));
      expect(out, contains('hello'));
      // Not the attached-documents heading, so Cypher can tell them apart.
      expect(out, isNot(contains('attached documents')));
    });

    test('short contents ride along unchanged', () {
      const text = 'print("hey")';
      final out = IdeFile.formatContext(
        path: '/projects/app.py',
        text: text,
      );
      expect(out.split('--- app.py ---\n').last, text);
    });

    test('long contents are capped at 4000 chars like an attached doc',
        () {
      // A marker past the cap proves the tail is dropped, not just
      // shortened: ellipsize cuts at the last space before the cap, so
      // the marker (which starts at char 3991) must not survive.
      final text = '${'a' * 3990} MARKER-BEYOND-CAP ${'b' * 900}';
      expect(text.length, greaterThan(IdeFile.maxContextChars));
      final out = IdeFile.formatContext(
        path: '/projects/notes.txt',
        text: text,
      );
      final body = out.split('--- notes.txt ---\n').last;
      expect(body.length, lessThanOrEqualTo(IdeFile.maxContextChars + 1));
      expect(body, endsWith('…'));
      expect(body, isNot(contains('MARKER')));
    });
  });

  group('readContext', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ide_file_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('no active file yields nothing', () async {
      expect(await IdeFile.readContext(null), isNull);
      expect(await IdeFile.readContext(''), isNull);
    });

    test('a remembered file that is gone yields nothing', () async {
      expect(
        await IdeFile.readContext('${tmp.path}/gone.txt'),
        isNull,
      );
    });

    test('an existing file yields its contents as a headed block',
        () async {
      final file = File('${tmp.path}/app.py');
      await file.writeAsString('print("hey")');
      final out = await IdeFile.readContext(file.path);
      expect(out, isNotNull);
      expect(out, contains('--- app.py ---'));
      expect(out, contains('print("hey")'));
    });

    test('a file that cannot be read as text yields nothing', () async {
      final file = File('${tmp.path}/blob.bin');
      await file.writeAsBytes([0xFF, 0xFE, 0xFD]);
      expect(await IdeFile.readContext(file.path), isNull);
    });
  });

  group('clearsActiveFile', () {
    test('deleting the active file clears the remembered path', () {
      expect(
        IdeFile.clearsActiveFile(
          activePath: '/projects/app.py',
          deletedPath: '/projects/app.py',
        ),
        isTrue,
      );
    });

    test('deleting any other file leaves the active file alone', () {
      expect(
        IdeFile.clearsActiveFile(
          activePath: '/projects/app.py',
          deletedPath: '/projects/notes.txt',
        ),
        isFalse,
      );
    });

    test('no active file means nothing to clear', () {
      expect(
        IdeFile.clearsActiveFile(
          activePath: null,
          deletedPath: '/projects/app.py',
        ),
        isFalse,
      );
      expect(
        IdeFile.clearsActiveFile(
          activePath: '',
          deletedPath: '/projects/app.py',
        ),
        isFalse,
      );
    });
  });

  group('deleteFile', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ide_file_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('deletes the file from disk and reports success', () async {
      final file = File('${tmp.path}/doomed.txt');
      await file.writeAsString('x');
      expect(await IdeFile.deleteFile(file), isTrue);
      expect(await file.exists(), isFalse);
    });

    test('a missing file reports failure instead of throwing', () async {
      final file = File('${tmp.path}/never-there.txt');
      expect(await IdeFile.deleteFile(file), isFalse);
    });
  });

  group('activeFileAfterWrite', () {
    test('a successful project write becomes the active file', () {
      expect(
        IdeFile.activeFileAfterWrite(
          toolName: 'write_project_file',
          success: true,
          data: {
            'path': 'main.dart',
            'absolutePath': '/projects/main.dart',
          },
        ),
        '/projects/main.dart',
      );
    });

    test('any other tool leaves the active file alone', () {
      expect(
        IdeFile.activeFileAfterWrite(
          toolName: 'create_note',
          success: true,
          data: {'absolutePath': '/projects/note.txt'},
        ),
        isNull,
      );
    });

    test('a failed write leaves the active file alone', () {
      expect(
        IdeFile.activeFileAfterWrite(
          toolName: 'write_project_file',
          success: false,
          data: {'absolutePath': '/projects/main.dart'},
        ),
        isNull,
      );
    });

    test('a write with no reported path leaves the active file alone', () {
      expect(
        IdeFile.activeFileAfterWrite(
          toolName: 'write_project_file',
          success: true,
          data: {'path': 'main.dart'},
        ),
        isNull,
      );
      expect(
        IdeFile.activeFileAfterWrite(
          toolName: 'write_project_file',
          success: true,
          data: null,
        ),
        isNull,
      );
    });
  });
}
