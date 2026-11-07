/// Main screen with bottom navigation.
///
/// Six destinations. Chat and the model list are separate because picking a
/// model is a settings-shaped task, while Memory and Activity are read-mostly.
/// Browser is last on purpose: the original five keep their indices, so
/// nothing that addressed a tab by number moves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/motion.dart';
import '../providers/providers.dart';
import 'browser_screen.dart';
import 'chat_screen.dart';
import 'memory_screen.dart';
import 'activity_screen.dart';
import 'settings_screen.dart';
import 'tools_screen.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int _currentIndex = 0;

  /// The Browser tab's index. A link tapped in chat writes
  /// [browserOpenRequestProvider]; this shell switches to the tab and the
  /// BrowserScreen loads the URL.
  static const int _browserIndex = 5;

  // The tab bodies are held in a const list and never rebuilt, which is what
  // preserves each tab's state: rebuilding Chat would drop a half-typed
  // message, and rebuilding Settings would drop its scroll position.
  final List<Widget> _screens = const [
    ChatScreen(),
    MemoryScreen(),
    ToolsScreen(),
    ActivityScreen(),
    SettingsScreen(),
    BrowserScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // A chat link is a request to show the browser, not a rebuild: the
    // listener fires after the build, so setState here is safe.
    ref.listen<String?>(browserOpenRequestProvider, (previous, next) {
      if (next == null) return;
      if (_currentIndex != _browserIndex) {
        setState(() => _currentIndex = _browserIndex);
      }
    });

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < _screens.length; i++)
            _TabSlot(
              // Keyed by index so each slot's animation state survives the
              // rebuild that a tab switch triggers. Without this the incoming
              // tab would restart its slide on every subsequent tap.
              key: ValueKey<int>(i),
              selected: i == _currentIndex,
              child: _screens[i],
            ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant
                  .withValues(alpha: 0.5),
            ),
          ),
        ),
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            // Selected label at 11 px so it fits the ~60 dp slot; colours
            // match the app theme (primary when selected, muted otherwise).
            labelTextStyle: WidgetStateProperty.resolveWith((states) {
              final scheme = Theme.of(context).colorScheme;
              final base = Theme.of(context).textTheme.labelMedium;
              return base?.copyWith(
                fontSize: states.contains(WidgetState.selected) ? 11 : null,
                color: states.contains(WidgetState.selected)
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              );
            }),
          ),
          child: NavigationBar(
            // Label on the selected tab only: six labels never fit a
            // 360 dp bar, and the icons alone say enough for the rest.
            labelBehavior:
                NavigationDestinationLabelBehavior.onlyShowSelected,
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) =>
                setState(() => _currentIndex = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'Chat',
              ),
              NavigationDestination(
                icon: Icon(Icons.psychology_outlined),
                selectedIcon: Icon(Icons.psychology),
                label: 'Memory',
              ),
              NavigationDestination(
                icon: Icon(Icons.handyman_outlined),
                selectedIcon: Icon(Icons.handyman),
                label: 'Tools',
              ),
              NavigationDestination(
                icon: Icon(Icons.history_outlined),
                selectedIcon: Icon(Icons.history),
                label: 'Activity',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
              NavigationDestination(
                icon: Icon(Icons.public_outlined),
                selectedIcon: Icon(Icons.public),
                label: 'Browser',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tab's slot in the shell.
///
/// Every tab stays mounted — that is the whole point, and it is why switching
/// away from Chat and back does not lose a half-typed message. What animates is
/// only the opacity and offset, so the old tab fades and slides out under the
/// new one instead of both snapping into place at once.
///
/// [AnimatedOpacity] rather than a plain [Opacity] specifically because it
/// drops the subtree's paint entirely at zero opacity: with an [IndexedStack]
/// only the visible child was ever painted, and six screens painting
/// simultaneously on a mid-range phone is a real regression.
class _TabSlot extends StatelessWidget {
  const _TabSlot({super.key, required this.selected, required this.child});

  final bool selected;
  final Widget child;

  /// How far a tab travels as it changes. Short on purpose — this is a
  /// cross-fade with a hint of direction, not a carousel.
  static const double _slide = 12;

  static const Duration _duration = Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // An invisible tab must not be tappable, or a stray tap lands on
      // whatever is under it.
      ignoring: !selected,
      child: ExcludeSemantics(
        // Matches IndexedStack, which reported only the visible child to
        // screen readers; without this a TalkBack user would hear all five
        // tabs stacked on top of each other.
        excluding: !selected,
        child: AnimatedOpacity(
          opacity: selected ? 1 : 0,
          duration: _duration,
          curve: AppMotion.standard,
          child: TweenAnimationBuilder<Offset>(
            // TweenAnimationBuilder animates from wherever the previous tween
            // ended to the new `end`, so deselecting slides *down* out and
            // selecting slides *up* in without either direction being
            // special-cased. `tween` must be a real Tween: handing it a bare
            // Offset does not compile.
            tween: Tween<Offset>(
              begin: Offset.zero,
              end: Offset(0, selected ? 0 : _slide),
            ),
            duration: _duration,
            curve: AppMotion.standard,
            builder: (context, offset, child) =>
                Transform.translate(offset: offset, child: child),
            child: child,
          ),
        ),
      ),
    );
  }
}
