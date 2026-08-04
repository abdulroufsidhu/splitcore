// Account settings: email verification, data export, and closing the
// account. Profile editing stays in the home sheet where it already works.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../theme.dart';
import '../widgets/page_body.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.sdk,
    required this.me,
    required this.groups,
    required this.onSignedOut,
    this.isVerifiedOverride,
    this.resendVerificationOverride,
    this.deleteOverride,
    this.exportOverride,
  });

  /// Null only in widget tests, which supply the overrides below.
  final SplitcoreSdk? sdk;
  final AppUser me;

  /// The groups available to export. Passed in rather than re-fetched —
  /// the home screen already has them.
  final List<Group> groups;
  final VoidCallback onSignedOut;

  @visibleForTesting
  final bool? isVerifiedOverride;
  @visibleForTesting
  final Future<void> Function()? resendVerificationOverride;
  @visibleForTesting
  final Future<String> Function()? deleteOverride;
  @visibleForTesting
  final Future<String> Function(String groupId)? exportOverride;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late final bool _isVerified =
      widget.isVerifiedOverride ?? (widget.sdk?.auth.isEmailVerified ?? false);

  Future<void> _resendVerification() async {
    final resend =
        widget.resendVerificationOverride ??
        () => widget.sdk!.auth.requestEmailVerification(widget.me.email);
    await resend();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Verification email sent — check your inbox.')));
  }

  /// Copies the group's ledger to the clipboard rather than pulling in a
  /// share/file-picker dependency: the destination is a spreadsheet, and
  /// paste covers that in one stdlib call.
  Future<void> _exportGroup(Group group) async {
    final export = widget.exportOverride ?? (String id) => widget.sdk!.export.groupToCsv(id);
    try {
      final csv = await export(group.id);
      await Clipboard.setData(ClipboardData(text: csv));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Copied ${group.name} to the clipboard as CSV.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't export: $e")));
    }
  }

  Future<void> _deleteAccount() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Delete your account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This closes your account permanently. It cannot be undone.\n\n'
                'You must settle every outstanding balance first — the server '
                'will refuse otherwise.',
              ),
              const SizedBox(height: 12),
              const Text('Type DELETE to confirm:'),
              TextField(
                controller: controller,
                // Typed confirmation, not just a second tap: this is
                // irreversible and destroys data the user cannot get back.
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(hintText: 'DELETE'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: controller.text == 'DELETE'
                  ? () => Navigator.of(dialogContext).pop(true)
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              child: const Text('Delete forever'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      final delete = widget.deleteOverride ?? () => widget.sdk!.auth.deleteAccount();
      final outcome = await delete();
      if (!mounted) return;
      if (outcome == 'anonymized') {
        // The server kept the membership rows so other members' balances
        // stay correct. Say so — claiming a full deletion would be a lie.
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Account anonymized'),
            content: const Text(
              'You appear in expenses other people share, so your records '
              'could not be removed without changing their balances. Your '
              'name and email have been erased and the account is closed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      widget.onSignedOut();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't delete your account: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text('Account')),
      body: SafeArea(
        child: PageBody(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              ListTile(
                title: Text(widget.me.name.isEmpty ? widget.me.email : widget.me.name),
                subtitle: widget.me.name.isEmpty ? null : Text(widget.me.email),
              ),
              if (!_isVerified)
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: ListTile(
                    leading: const Icon(Icons.mark_email_unread_outlined),
                    title: const Text('Your email is not verified'),
                    subtitle: Text(
                      'Verify ${widget.me.email} so you can recover your account '
                      'if you forget your password.',
                    ),
                    trailing: TextButton(
                      onPressed: _resendVerification,
                      child: const Text('Resend'),
                    ),
                  ),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('EXPORT', style: sectionLabelStyle(slice.muted)),
              ),
              if (widget.groups.isEmpty)
                ListTile(
                  title: Text('No groups to export', style: TextStyle(color: slice.muted)),
                )
              else
                for (final group in widget.groups)
                  ListTile(
                    leading: const Icon(Icons.table_view_outlined),
                    title: Text(group.name),
                    subtitle: const Text('Copy ledger as CSV'),
                    onTap: () => _exportGroup(group),
                  ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: widget.onSignedOut,
              ),
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: slice.negative),
                title: Text('Delete account', style: TextStyle(color: slice.negative)),
                onTap: _deleteAccount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
