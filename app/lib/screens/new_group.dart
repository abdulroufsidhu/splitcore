// 1f — New group: name, currency (locked once created), members. Members
// entered here are invited by email right after the group is created —
// unknown emails auto-join the moment they sign up (see
// splitcore_sdk's GroupsApi.inviteOrAddMember and the server's
// /api/splitcore/invite route + invites collection).
import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../money.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/currency_picker.dart';
import '../widgets/page_body.dart';

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key, required this.sdk, this.createOverride, this.inviteOverride});

  /// Null only in widget tests, which supply the overrides below.
  final SplitcoreSdk? sdk;

  /// Test seams, so a test can prove which emails actually get invited
  /// without standing up an SDK and a server.
  @visibleForTesting
  final Future<Group> Function({required String name, required String currency})? createOverride;
  @visibleForTesting
  final Future<bool> Function({required String groupId, required String email})? inviteOverride;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  final _memberEmail = TextEditingController();
  final List<String> _pendingEmails = [];
  String _currency = 'USD';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _memberEmail.dispose();
    super.dispose();
  }

  void _addPendingEmail() {
    final email = _memberEmail.text.trim();
    if (email.isEmpty || _pendingEmails.contains(email)) return;
    setState(() {
      _pendingEmails.add(email);
      _memberEmail.clear();
    });
  }

  Future<void> _create() async {
    // Commit whatever is still sitting in the email field. Only "+" and the
    // keyboard's submit key fed _pendingEmails, so typing an address and
    // going straight for "Create group" — which is what the layout invites
    // you to do — dropped it silently and created the group with nobody in
    // it. The group detail screen's own add-member field reads its
    // controller directly and never had this problem.
    _addPendingEmail();

    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a group name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final create = widget.createOverride ?? widget.sdk!.groups.createGroup;
      final invite = widget.inviteOverride ?? widget.sdk!.groups.inviteOrAddMember;
      final group = await create(name: _name.text.trim(), currency: _currency);
      final failures = <String>[];
      for (final email in _pendingEmails) {
        try {
          await invite(groupId: group.id, email: email);
        } catch (_) {
          failures.add(email);
        }
      }
      if (!mounted) return;
      if (failures.isNotEmpty) {
        setState(() => _error = "Group created, but couldn't invite: ${failures.join(', ')}");
        return;
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 88,
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: slice.muted)),
        ),
        title: const Text('New group'),
      ),
      body: SafeArea(
        child: PageBody(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text('GROUP NAME', style: sectionLabelStyle(slice.muted)),
                const SizedBox(height: 8),
                TextField(
                  controller: _name,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: slice.ink),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: slice.card,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: slice.border),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('CURRENCY', style: sectionLabelStyle(slice.muted)),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    final picked = await pickCurrency(context, _currency);
                    if (picked != null) setState(() => _currency = picked);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: slice.card,
                      border: Border.all(color: slice.border),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Text(
                          currencySymbol(_currency),
                          style: moneyStyle(size: 18, color: slice.ink),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _currency,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: slice.ink,
                          ),
                        ),
                        const Spacer(),
                        Icon(Icons.unfold_more, size: 18, color: slice.muted),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "One currency per group — this can't be changed later.",
                  style: TextStyle(fontSize: 12, color: slice.muted),
                ),
                const SizedBox(height: 20),
                Text('MEMBERS', style: sectionLabelStyle(slice.muted)),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: slice.card,
                    border: Border.all(color: slice.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: Avatar('Y', background: slice.ink, foreground: slice.paper, size: 30),
                    title: const Text(
                      'You',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                    ),
                    trailing: Text('Owner', style: TextStyle(fontSize: 12, color: slice.muted)),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _memberEmail,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Invite by email'),
                        onSubmitted: (_) => _addPendingEmail(),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Add this email',
                      icon: const Icon(Icons.add),
                      onPressed: _addPendingEmail,
                    ),
                  ],
                ),
                if (_pendingEmails.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final email in _pendingEmails)
                        Chip(
                          label: Text(email),
                          onDeleted: () => setState(() => _pendingEmails.remove(email)),
                        ),
                    ],
                  ),
                const SizedBox(height: 4),
                Text(
                  "If they don't have a SlicePay account yet, they'll join this group "
                  'automatically once they sign up with that email.',
                  style: TextStyle(fontSize: 12, color: slice.muted),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: slice.negative)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _create,
                  child: _saving
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: slice.paper),
                        )
                      : const Text('Create group'),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
