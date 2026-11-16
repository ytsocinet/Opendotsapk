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
import 'package:flutter/services.dart';
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

      // The export's first step is getTemporaryDirectory(), a
      // path_provider channel call with no mock in a widget test. An
      // unmocked channel call never returns — it hangs the export
      // forever instead of failing — so the mock fails it fast, and
      // the editor's catch shows the failure as a snackbar.
      const pathProviderChannel =
          MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, (call) async {
        throw PlatformException(
          code: 'unavailable',
          message: 'no path_provider in a widget test',
        );
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
      });

      // The editor loads the file with real dart:io I/O. A read started
      // in the widget-test (FakeAsync) zone never completes — the editor
      // stays on its indeterminate spinner and the TextField never
      // appears (builds #107 and #108 both failed here, and a runAsync
      // delay after pumpWidget does not help either, because the read
      // was already started in the fake zone). Starting the pump inside
      // runAsync lets the read run in the real zone, so it finishes in
      // real time; one pump after that renders it.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides,
            child: MaterialApp(home: CodeEditorScreen(path: filePath)),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump();

      expect(find.text('hello.dart'), findsOneWidget);
      expect(find.byTooltip('Download file'), findsOneWidget);
      // Pin the loaded state before tapping: the editor field is only
      // built once the file has loaded, so this fails fast with a
      // clear message instead of silently tapping a disabled button.
      // The error text is checked too: if the read itself failed, the
      // next failure should say so instead of a bare "0 TextFields".
      expect(find.textContaining('Could not read'), findsNothing);
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
