/// The editor's Download button is wired to the export path.
///
/// Build #107: one tap on the open file hands it to the share sheet so
/// Aaron can save it to Downloads, Drive, or send it elsewhere. On a
/// phone the share sheet opens; in a widget test there is no share sheet
/// (path_provider has no platform channel here), so the test pins the
/// failure path instead — tapping Download must not crash, and the error
/// must surface as a readable message rather than a silent nothing.
///
/// The editor only reads the settings provider when deleting, but it is
/// still a ConsumerWidget, so the scope carries the same in-memory fake
/// the Prompt Lab dispose test uses.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clawzilla/presentation/providers/providers.dart';
import 'package:clawzilla/presentation/screens/code_editor_screen.dart';

class _FakeSettingsNotifier extends SettingsNotifier {
  _FakeSettingsNotifier() : super.test({});
}

void main() {
  group('CodeEditorScreen download (build #107)', () {
    late Directory tempDir;
    late String filePath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('clawzilla-export-');
      final file = File('${tempDir.path}/hello.dart');
      await file.writeAsString('void main() {}\n');
      filePath = file.path;
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    testWidgets('Download button exists and its failure surfaces',
        (tester) async {
      final settings = _FakeSettingsNotifier();
      final overrides = <Override>[
        settingsProvider.overrideWith((ref) => settings),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp(home: CodeEditorScreen(path: filePath)),
        ),
      );
      // The editor loads the file asynchronously, so give the read time
      // to finish and the rebuild time to run before tapping anything.
      // This matters: while loading, the body is an indeterminate
      // CircularProgressIndicator (which schedules frames forever, so
      // pumpAndSettle would never settle on it) and the Download
      // button is disabled, so a tap before the load finishes is a
      // no-op and no snackbar ever appears. The TextField itself is
      // not autofocused, so no cursor blink is involved.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('hello.dart'), findsOneWidget);
      expect(find.byTooltip('Download file'), findsOneWidget);
      // Pin the loaded state before tapping: the editor field is only
      // built once the file has loaded, so this fails fast with a
      // clear message instead of silently tapping a disabled button.
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(find.byTooltip('Download file'));
      // Bounded pumps, not pumpAndSettle: the export fails fast here
      // (no path_provider channel in a widget test) and the snackbar
      // needs a frame to appear. Three short pumps are enough for the
      // failure to surface, and 300ms total stays well under the
      // snackbar's 4s auto-dismiss.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // No share sheet in a widget test, so the export fails here — but
      // it must fail loudly and leave the editor usable.
      expect(find.textContaining('Could not export'), findsOneWidget);
      expect(find.text('hello.dart'), findsOneWidget);
    });
  });
}
