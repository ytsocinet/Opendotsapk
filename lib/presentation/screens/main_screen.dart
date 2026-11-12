/// Main screen with a left slide-out drawer.
///
/// Six destinations. Chat and the model list are separate because picking a
/// model is a settings-shaped task, while Memory and Activity are read-mostly.
/// Browser is last on purpose: the original five keep their indices, so
/// nothing that addressed a tab by number moves. The drawer opens from the
/// menu button in the chat header, from the menu button on the other tabs'
/// app bars, or by swiping in from the left edge.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
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
      drawer: _buildDrawer(context),
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
    );
  }

  /// The slide-out navigation drawer: the saved chats up top (New chat plus
  /// the list, most recent first), then the six destinations that used to
  /// live in a fixed bottom bar. Tapping one closes the drawer and switches
  /// to that tab; the tab bodies stay mounted either way, so switching
  /// never drops a half-typed message.
  Widget _buildDrawer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // The saved chats live in the drawer so starting a new one is one tap
    // from anywhere — no more clearing the only conversation to start over.
    final conversations = ref.watch(conversationsProvider);
    final activeId = ref.watch(activeConversationIdProvider);

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.brand.withValues(alpha: 0.4),
                      ),
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/clawzilla-mark.png',
                        width: 36,
                        height: 36,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('CLAWZILLA', style: textTheme.titleLarge),
                      Text(
                        'LOCAL AGENT',
                        style: textTheme.labelSmall?.copyWith(
                          letterSpacing: 2.0,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.add, color: scheme.primary),
              title: const Text('New chat'),
              onTap: () async {
                Navigator.of(context).pop();
                await ref.read(conversationsProvider.notifier).createNew();
                if (mounted && _currentIndex != 0) {
                  setState(() => _currentIndex = 0);
                }
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'CHATS',
                style: textTheme.labelSmall?.copyWith(
                  letterSpacing: 2.0,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: conversations.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        'No saved chats yet.',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        final selected = conversation.id == activeId;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.chat_bubble_outline,
                            color: selected
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          title: Text(
                            conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected ? scheme.primary : null,
                              fontWeight:
                                  selected ? FontWeight.w600 : null,
                            ),
                          ),
                          selected: selected,
                          selectedTileColor:
                              scheme.primary.withValues(alpha: 0.12),
                          onTap: () async {
                            Navigator.of(context).pop();
                            await ref
                                .read(conversationsProvider.notifier)
                                .switchTo(conversation.id);
                            if (mounted && _currentIndex != 0) {
                              setState(() => _currentIndex = 0);
                            }
                          },
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: 'Delete chat',
                            color: scheme.onSurfaceVariant,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 36,
                              height: 36,
                            ),
                            onPressed: () => _confirmDeleteConversation(
                              context,
                              conversation,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            _drawerTile(
              index: 0,
              icon: Icons.chat_bubble_outline,
              selectedIcon: Icons.chat_bubble,
              label: 'Chat',
            ),
            _drawerTile(
              index: 1,
              icon: Icons.psychology_outlined,
              selectedIcon: Icons.psychology,
              label: 'Memory',
            ),
            _drawerTile(
              index: 2,
              icon: Icons.handyman_outlined,
              selectedIcon: Icons.handyman,
              label: 'Tools',
            ),
            _drawerTile(
              index: 3,
              icon: Icons.history_outlined,
              selectedIcon: Icons.history,
              label: 'Activity',
            ),
            _drawerTile(
              index: 4,
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              label: 'Settings',
            ),
            _drawerTile(
              index: 5,
              icon: Icons.public_outlined,
              selectedIcon: Icons.public,
              label: 'Browser',
            ),
          ],
        ),
      ),
    );
  }

  /// Deletes a chat after asking. The drawer stays open on Cancel; on
  /// Delete the conversation (and its messages) is gone for good. If it
  /// was the open chat, the next most recent one opens instead.
  Future<void> _confirmDeleteConversation(
    BuildContext context,
    Conversation conversation,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          '"${conversation.title}" and all its messages will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(conversationsProvider.notifier).delete(conversation.id);
    }
  }

  /// One destination row in the drawer. Same icons and labels as the old
  /// bottom bar; the selected row is tinted so the current tab is visible
  /// at a glance.
  Widget _drawerTile({
    required int index,
    required IconData icon,
    required IconData selectedIcon,
    required String label,
  }) {
    final selected = index == _currentIndex;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        selected ? selectedIcon : icon,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        label,
        style: TextStyle(
          color: selected ? scheme.primary : null,
          fontWeight: selected ? FontWeight.w600 : null,
        ),
      ),
      selected: selected,
      selectedTileColor: scheme.primary.withValues(alpha: 0.12),
      onTap: () {
        Navigator.of(context).pop();
        if (!selected) setState(() => _currentIndex = index);
      },
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
