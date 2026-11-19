/// Auto-reply screen (build #123, Auto-reply Piece A).
///
/// The drawer opens this screen. Master toggle (off by default), the
/// per-contact rules list, and the recent auto-replies — what was SENT,
/// not what arrived. There is no inbox: incoming message bodies are
/// never shown here, never stored, and never logged.
///
/// Turning the master on asks for the SMS permission (which covers
/// SEND_SMS and RECEIVE_SMS) in the foreground, with the reason on the
/// screen next to the switch — the prompt must say what it is for, in
/// Aaron's words, at the moment he turns it on, not at first install
/// (plan §5). A denied grant leaves the master off with a SnackBar
/// saying why.
///
/// Adding a rule: type a name and a number, or pick a contact from the
/// device list (READ_CONTACTS, already granted for the SMS name lookup),
/// then write the template — the exact text Cypher sends back, word
/// for word. One reply per contact per cooldown window (30 minutes by
/// default); a second text inside the window gets nothing.
library;

import 'dart:convert';

import 'package:clawzilla_auto_reply/clawzilla_auto_reply.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/services/auto_reply_service.dart';
import '../../domain/models/auto_reply_rule.dart';
import '../providers/auto_reply_provider.dart';
import '../providers/providers.dart';
import '../widgets/screen_empty_state.dart';

/// The template a new rule starts with: Aaron edits it to his own
/// words. It is a starting point, not a default that ever sends
/// without him writing (or keeping) it.
const String _defaultTemplate =
    "Hey, I'm busy — I'll get back to you. - Aaron";

class AutoReplyScreen extends ConsumerStatefulWidget {
  const AutoReplyScreen({super.key});

  @override
  ConsumerState<AutoReplyScreen> createState() => _AutoReplyScreenState();
}

class _AutoReplyScreenState extends ConsumerState<AutoReplyScreen> {
  late final TextEditingController _myNumberController;

  /// Once Aaron edits the field, the controller owns the text: a later
  /// rebuild must not reseed it from the stored value and fight his
  /// typing. Before the first edit, the stored value seeds it once.
  bool _myNumberEdited = false;

  @override
  void initState() {
    super.initState();
    _myNumberController = TextEditingController();
  }

  @override
  void dispose() {
    _myNumberController.dispose();
    super.dispose();
  }

  /// Turning the master on needs the SMS permission first — the
  /// background task cannot show a permission dialog, so a grant made
  /// later would never happen. SEND_SMS and RECEIVE_SMS ride together
  /// in permission_handler's sms group, so one request covers both.
  Future<void> _setMasterEnabled(bool enabled) async {
    if (enabled) {
      final status = await Permission.sms.request();
      if (!status.isGranted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Auto-reply stays off: SMS permission is needed to receive '
              'texts and send the reply.',
            ),
          ),
        );
        return;
      }
    }
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('auto_reply_enabled', enabled);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AutoReplyRule rule,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete rule?'),
        content: Text(
          '"${rule.contactName.isEmpty ? rule.phoneNumber : rule.contactName}" '
          'will stop getting auto-replies. This can’t be undone.',
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
      await ref.read(autoReplyRulesProvider.notifier).deleteRule(rule.id);
    }
  }

  void _openRuleEditor({AutoReplyRule? rule}) {
    showDialog<void>(
      context: context,
      builder: (context) => _RuleEditorDialog(
        rule: rule,
        onSave: (name, number, template) async {
          if (rule == null) {
            await ref
                .read(autoReplyRulesProvider.notifier)
                .createRule(
                  contactName: name,
                  phoneNumber: number,
                  templateText: template,
                );
          } else {
            await ref
                .read(autoReplyRulesProvider.notifier)
                .updateRule(
                  rule.copyWith(
                    contactName: name,
                    phoneNumber: number,
                    templateText: template,
                  ),
                );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rules = ref.watch(autoReplyRulesProvider);
    final settings = ref.watch(settingsProvider);
    final masterEnabled = settings['auto_reply_enabled'] as bool? ?? false;
    final cooldownMinutes =
        settings['auto_reply_cooldown_minutes'] as int? ?? 30;
    final myNumber = settings['my_phone_number'] as String? ?? '';
    if (!_myNumberEdited && _myNumberController.text != myNumber) {
      // Seed the field from the stored value once; afterwards the
      // controller owns the text so typing does not fight rebuilds.
      _myNumberController.text = myNumber;
    }
    final recent = ref
        .watch(activityLogProvider)
        .where((entry) => entry['tool_name'] == 'auto_reply')
        .take(20)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Auto-reply'),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          tooltip: 'Menu',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openRuleEditor(),
        tooltip: 'New rule',
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto-reply'),
                    subtitle: const Text(
                      'When on, Cypher replies to texts from your chosen '
                      'contacts below with the template you wrote — '
                      'nothing else, no one else. SMS only.',
                    ),
                    value: masterEnabled,
                    onChanged: (value) => _setMasterEnabled(value),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'One reply per contact every $cooldownMinutes minutes. '
                    'Replies land seconds to about a minute after the text '
                    'arrives.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _myNumberController,
                    decoration: const InputDecoration(
                      labelText: 'My number (optional)',
                      helperText:
                          'Your own number, so Cypher never replies to it. '
                          'Leave blank to skip the check.',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.phone,
                    onChanged: (_) => _myNumberEdited = true,
                    onSubmitted: (value) async {
                      await ref
                          .read(settingsProvider.notifier)
                          .updateSetting(
                            'my_phone_number',
                            value.trim(),
                          );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'RULES · ${rules.length}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 2.0,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (rules.isEmpty)
            const ScreenEmptyState(
              icon: Icons.reply_outlined,
              title: 'No contacts opted in yet',
              message:
                  'Add a contact and write the reply they get. A text from '
                  'anyone without a rule gets nothing — silence, not a reply.',
            )
          else
            ...rules.map(
              (rule) => Card(
                child: ListTile(
                  title: Text(
                    rule.contactName.isEmpty
                        ? rule.phoneNumber
                        : rule.contactName,
                  ),
                  subtitle: Text(
                    '${rule.phoneNumber}\n${rule.templateText}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: rule.enabled,
                        onChanged: (value) => ref
                            .read(autoReplyRulesProvider.notifier)
                            .setRuleEnabled(rule.id, value),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete rule',
                        onPressed: () => _confirmDelete(context, rule),
                      ),
                    ],
                  ),
                  onTap: () => _openRuleEditor(rule: rule),
                ),
              ),
            ),
          const SizedBox(height: 24),
          Text(
            'RECENT AUTO-REPLIES',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 2.0,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            const ScreenEmptyState(
              icon: Icons.history,
              title: 'Nothing sent yet',
              message:
                  'Every auto-reply Cypher sends is listed here, newest '
                  'first — what was sent, never what arrived.',
            )
          else
            ...recent.map((entry) => _RecentReplyTile(entry: entry)),
        ],
      ),
    );
  }
}

/// One sent auto-reply, from the activity log: who it went to, when,
/// and whether it went out. The log params carry the recipient and the
/// rule id — never the incoming body, which is not logged anywhere.
class _RecentReplyTile extends StatelessWidget {
  const _RecentReplyTile({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final params = _decodeParams(entry['params']);
    final name = params['contact_name'] as String?;
    final recipient = params['recipient'] as String?;
    final who = (name != null && name.isNotEmpty)
        ? '$name (${recipient ?? ''})'
        : (recipient ?? 'Unknown');
    final status = '${entry['status'] ?? ''}';
    final isSuccess = status == 'success';
    final timestamp = entry['timestamp'] as int?;
    final date = timestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(timestamp);

    return Card(
      child: ListTile(
        leading: Icon(
          isSuccess ? Icons.check_circle_outline : Icons.error_outline,
          color: isSuccess ? scheme.primary : scheme.error,
        ),
        title: Text(who),
        subtitle: Text(
          date == null
              ? (isSuccess ? 'Sent' : 'Failed to send')
              : '${date.day}/${date.month}/${date.year} '
                  '${date.hour}:${date.minute.toString().padLeft(2, '0')} · '
                  '${isSuccess ? 'Sent' : 'Failed to send'}',
        ),
      ),
    );
  }

  Map<String, dynamic> _decodeParams(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // A hand-edited or legacy params value: show the row without it.
      }
    }
    return const {};
  }
}

/// Add/edit dialog for one rule: name, number, template. A new rule
/// starts with the example template; editing keeps the stored one.
///
/// "Choose from contacts" lists the device contacts (READ_CONTACTS)
/// and fills the name and number from the pick — or type both by hand.
/// The number must normalise to at least 7 digits: short codes can
/// never be replied to, so they cannot become a rule either.
class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog({required this.rule, required this.onSave});

  final AutoReplyRule? rule;
  final Future<void> Function(
    String name,
    String number,
    String template,
  )
  onSave;

  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _numberController;
  late final TextEditingController _templateController;
  String? _error;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.contactName ?? '');
    _numberController = TextEditingController(
      text: rule?.phoneNumber ?? '',
    );
    _templateController = TextEditingController(
      text: rule?.templateText ?? _defaultTemplate,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _numberController.dispose();
    _templateController.dispose();
    super.dispose();
  }

  Future<void> _pickContact() async {
    final status = await Permission.contacts.request();
    if (!status.isGranted) {
      setState(() {
        _error = 'Contacts permission is needed to pick a contact — '
            'or type the number by hand.';
      });
      return;
    }
    List<AutoReplyContact> contacts;
    try {
      contacts = await AutoReplySms.listContacts();
    } catch (e) {
      setState(() => _error = 'Could not list contacts: $e');
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<AutoReplyContact>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose a contact'),
        children: [
          SizedBox(
            width: double.maxFinite,
            height: 400,
            child: contacts.isEmpty
                ? const Center(child: Text('No contacts with numbers.'))
                : ListView.builder(
                    itemCount: contacts.length,
                    itemBuilder: (context, index) {
                      final contact = contacts[index];
                      return ListTile(
                        title: Text(contact.name),
                        subtitle: Text(contact.number),
                        onTap: () =>
                            Navigator.pop(context, contact),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
    if (picked != null) {
      setState(() {
        _nameController.text = picked.name;
        _numberController.text = picked.number;
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final number = _numberController.text.trim();
    final template = _templateController.text.trim();
    if (normalizePhoneNumber(number).length < 7) {
      setState(() {
        _error = 'Enter a full phone number — short codes can never '
            'be replied to.';
      });
      return;
    }
    if (template.isEmpty) {
      setState(() => _error = 'Write the reply text first.');
      return;
    }
    await widget.onSave(name, number, template);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.rule == null;
    return AlertDialog(
      title: Text(isNew ? 'New auto-reply rule' : 'Edit auto-reply rule'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _numberController,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _pickContact,
                icon: const Icon(Icons.contacts_outlined),
                label: const Text('Choose from contacts'),
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _templateController,
              decoration: const InputDecoration(
                labelText: 'Reply text',
                helperText:
                    'Sent exactly as written, word for word.',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(isNew ? 'Add rule' : 'Save'),
        ),
      ],
    );
  }
}
