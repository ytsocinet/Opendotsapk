/// One row of the chat transcript.
///
/// Replaces the undifferentiated bubble that every message used to get. The two
/// roles are separated by colour, alignment, and an avatar on the assistant
/// side, so a long transcript can be scanned without reading it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../domain/models/models.dart';
import '../providers/providers.dart';
import '../screens/browser_screen.dart';

/// Split an assistant reply into its reasoning and its answer.
///
/// Reasoning models (MiniCPM5, Qwen3, DeepSeek-R1 style) emit their
/// chain-of-thought inside `<think>...</think>` and the answer after
/// `</think>`. The tile used to render that whole raw output in one bubble,
/// so the thinking and the answer ran together. Returns the thinking text
/// (empty when there is none) and the answer text.
///
/// An unclosed `<think>` — the reply was stopped mid-thought — puts
/// everything after the tag into thinking. Text before `<think>` (a model
/// that chats first, then thinks) is kept as part of the answer.
({String thinking, String answer}) splitThinking(String content) {
  final open = content.indexOf('<think>');
  if (open < 0) {
    // No opener. A lone closer still marks where the reasoning ends:
    // everything before it is thinking, everything after is the answer.
    // This covers replies whose opening tag was stripped before the
    // stripper learned to preserve it, and models that only emit the
    // closer.
    final loneClose = content.indexOf('</think>');
    if (loneClose < 0) return (thinking: '', answer: content);
    return (
      thinking: content.substring(0, loneClose).trim(),
      answer: content.substring(loneClose + 8).trim(),
    );
  }
  final close = content.indexOf('</think>', open + 7);
  final before = content.substring(0, open).trim();
  if (close < 0) {
    return (thinking: content.substring(open + 7).trim(), answer: before);
  }
  final thinking = content.substring(open + 7, close).trim();
  final after = content.substring(close + 8).trim();
  final answer = before.isEmpty ? after : '$before\n\n$after'.trim();
  return (thinking: thinking, answer: answer);
}

/// Renders a single [ChatMessage] as an avatar-and-bubble row.
///
/// Text stays inside a [SelectableText] so long-press to copy, and the
/// selectable-region behaviour users already rely on, is unchanged.
///
/// Links in an assistant reply open in the Browser tab (through
/// [browserOpenRequestProvider]) instead of leaving the app. Today nothing
/// else in the app opens links at all — there is no url_launcher — so this
/// is the first tappable link in the app.
class ChatMessageTile extends ConsumerStatefulWidget {
  const ChatMessageTile({super.key, required this.message});

  final ChatMessage message;

  @override
  ConsumerState<ChatMessageTile> createState() => _ChatMessageTileState();
}

class _ChatMessageTileState extends ConsumerState<ChatMessageTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.role == 'user';
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final maxWidth = MediaQuery.of(context).size.width * 0.85;

    return FadeSlideIn(
      duration: const Duration(milliseconds: 400),
      dy: 0.04,
      child: ScaleTransition(
        scale: CurvedAnimation(
          parent: _controller,
          curve: AppMotion.enter,
          reverseCurve: AppMotion.exit,
        ),
        child: _buildMessage(isUser, scheme, text, maxWidth, theme),
      ),
    );
  }

  Widget _buildMessage(
    bool isUser,
    ColorScheme scheme,
    TextTheme text,
    double maxWidth,
    ThemeData theme,
  ) {
    final bubble = _buildBubble(isUser, scheme, text, maxWidth, theme);

    if (isUser) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AssistantAvatar(),
        const SizedBox(width: 10),
        Flexible(child: bubble),
      ],
    );
  }

  Widget _buildBubble(
    bool isUser,
    ColorScheme scheme,
    TextTheme text,
    double maxWidth,
    ThemeData theme,
  ) {
    // Split the model's reasoning out of the answer, when it is there, so
    // the thinking gets its own collapsible box instead of running together
    // with the answer in one bubble. For user messages (and replies with no
    // `<think>` block) this is a no-op: thinking is empty, answer is the
    // whole content.
    final split = splitThinking(widget.message.content);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(maxWidth: maxWidth),
      decoration: BoxDecoration(
        color: isUser ? AppColors.userBubble : AppColors.aiBubble,
        // Clawziod look: terminal panels — 12 px rounding and a thin green
        // border on both roles (the user bubble used to have no border).
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: AppColors.brand.withValues(alpha: isUser ? 0.25 : 0.35),
        ),
        boxShadow: isUser
            ? [
                BoxShadow(
                  color: AppColors.brand.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                  spreadRadius: 0,
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                  spreadRadius: 0,
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isUser)
            Row(
              children: [
                Text(
                  'Cypher',
                  style: text.labelMedium?.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_hasTime)
                  Text(
                    _formatTime(widget.message.timestamp),
                    style: text.labelSmall,
                  ),
              ],
            ),
          if (!isUser) const SizedBox(height: 6),
          if (isUser)
            SelectableText(widget.message.content, style: text.bodyLarge)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The reasoning is split out of the answer above and never
                // rendered: Aaron does not want to see what the model was
                // thinking, so only the answer shows. The thinking stays
                // in the stored message; it is just never displayed.
                if (split.answer.isNotEmpty)
                  MarkdownBody(
                    data: split.answer,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(theme),
                    // A tapped link opens in the Browser tab. Plain words
                    // that are not a URL become a Brave Search instead.
                    onTapLink: (text, href, title) {
                      if (href == null || href.isEmpty) return;
                      ref.read(browserOpenRequestProvider.notifier).state =
                          toBrowsableUrl(href);
                    },
                  ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () async {
                      // Copy the answer, not the reasoning — that is the
                      // part the user wants to keep or share. Falls back to
                      // the full content when the answer is empty (a reply
                      // stopped mid-thought).
                      await Clipboard.setData(
                        ClipboardData(
                          text: split.answer.isNotEmpty
                              ? split.answer
                              : widget.message.content,
                        ),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            const SnackBar(
                              content: Text('Copied to clipboard'),
                            ),
                          );
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.copy_rounded, size: 14),
                    ),
                  ),
                ),
              ],
            ),
          if (isUser && _hasTime) ...[
            const SizedBox(height: 5),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _formatTime(widget.message.timestamp),
                style: text.labelSmall?.copyWith(color: Colors.white70),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A zero timestamp means "not recorded"; there is nothing honest to show.
  bool get _hasTime => widget.message.timestamp > 0;

  /// `HH:MM` in device-local time.
  ///
  /// Formatted by hand rather than through `intl` so the transcript needs no
  /// additional dependency for the one format it needs.
  static String _formatTime(int millisSinceEpoch) {
    final at = DateTime.fromMillisecondsSinceEpoch(millisSinceEpoch);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}';
  }
}

/// The assistant's leading glyph.
///
/// Small, low-contrast, and green: it marks authorship without turning every
/// reply into an avatar that competes with the text.
///
/// [theme] is passed through from [_buildMessage] so MarkdownStyleSheet can
/// read the app's colour tokens instead of inventing its own defaults.
class _AssistantAvatar extends StatefulWidget {
  @override
  State<_AssistantAvatar> createState() => _AssistantAvatarState();
}

class _AssistantAvatarState extends State<_AssistantAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.28)),
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(
                  alpha: 0.15 + (0.1 * _pulseController.value),
                ),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/clawzilla-mark.png',
              width: 16,
              height: 16,
              fit: BoxFit.cover,
            ),
          ),
        );
      },
    );
  }
}
