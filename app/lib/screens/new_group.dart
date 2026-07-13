// 1f — New group: name, currency (locked once created), members. Real
// invite-by-email needs a users lookup the default PocketBase `users`
// rules don't expose to non-superusers (verified: 404) — see
// display_name.dart. Contacts picker / share-link join are native-app and
// backend-schema work respectively; out of scope for v1 (flagged in plan).
import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../money.dart';
import '../theme.dart';
import '../widgets/avatar.dart';

const _currencies = ['USD', 'EUR', 'GBP'];

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key, required this.sdk});

  final SplitcoreSdk sdk;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  String _currency = 'USD';
  bool _saving = false;
  String? _error;

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a group name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.sdk.groups.createGroup(name: _name.text.trim(), currency: _currency);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: SliceColors.muted)),
        ),
        title: const Text('New group'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            const Text('GROUP NAME', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: SliceColors.muted)),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: SliceColors.ink),
              decoration: InputDecoration(
                filled: true,
                fillColor: SliceColors.card,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: SliceColors.border)),
              ),
            ),
            const SizedBox(height: 20),
            const Text('CURRENCY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: SliceColors.muted)),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final c in _currencies)
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _currency = c),
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: _currency == c ? SliceColors.ink : SliceColors.card,
                          border: Border.all(color: _currency == c ? SliceColors.ink : SliceColors.border),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          children: [
                            Text(
                              currencySymbol(c),
                              style: moneyStyle(size: 16, color: _currency == c ? SliceColors.paper : SliceColors.ink),
                            ),
                            const SizedBox(height: 2),
                            Text(c, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _currency == c ? SliceColors.paper.withValues(alpha: 0.7) : SliceColors.muted)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text("One currency per group — this can't be changed later.", style: TextStyle(fontSize: 12, color: SliceColors.muted)),
            const SizedBox(height: 20),
            const Text('MEMBERS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: SliceColors.muted)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(color: SliceColors.card, border: Border.all(color: SliceColors.border), borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: const Avatar('Y', background: SliceColors.ink, foreground: SliceColors.paper, size: 30),
                title: const Text('You', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                trailing: const Text('Owner', style: TextStyle(fontSize: 12, color: SliceColors.muted)),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Invite others after creating the group, from group detail — '
              'they need to already have a SlicePay account.',
              style: TextStyle(fontSize: 12, color: SliceColors.muted),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: SliceColors.negative)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _create,
              style: FilledButton.styleFrom(
                backgroundColor: SliceColors.ink,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
              child: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Create group'),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
