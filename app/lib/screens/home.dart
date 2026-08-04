// 1a — Home: groups & balances. The groups list *is* the app (no tab bar);
// account/sign-out lives behind the header avatar.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../display_name.dart';
import '../money.dart';
import '../loadable.dart';
import '../offline_cache.dart';
import '../relative_time.dart';
import '../theme.dart';
import '../widgets/async_section.dart';
import '../widgets/avatar.dart';
import '../widgets/currency_picker.dart';
import '../widgets/money_text.dart';
import '../widgets/page_body.dart';
import '../widgets/skeleton.dart';
import 'account.dart';
import 'activity.dart';
import 'group_detail.dart';
import 'new_group.dart';

/// One row's worth of data: the group plus *my* net balance within it.
/// One row's worth of data. Public so a widget test can build fixtures
/// without an SDK.
class GroupRow {
  GroupRow(
    this.group,
    this.myMemberId,
    this.myNetCents,
    this.memberCount,
    this.directName,
    this.directAvatarUrl,
  );

  /// A row rebuilt from the offline cache. myMemberId is empty because
  /// nothing cached can be tapped through to a live action.
  factory GroupRow.fromCache(GroupSummary summary) => GroupRow(
    Group(id: summary.id, name: summary.name, currency: summary.currency, version: 0, ownerId: ''),
    '',
    summary.myNetCents,
    summary.memberCount,
    '',
    '',
  );

  final Group group;
  final String myMemberId;
  final int myNetCents;
  final int memberCount;

  /// For a direct (1:1) group: the other person's resolved name/avatar
  /// (see directPersonName) — '' for a regular multi-member group.
  final String directName;
  final String directAvatarUrl;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.sdk,
    required this.me,
    required this.onSignedOut,
    required this.onProfileUpdated,
    this.cache,
    this.loadOverride,
  });

  /// Null only in widget tests, which supply [loadOverride] instead.
  final SplitcoreSdk? sdk;
  final AppUser me;
  final VoidCallback onSignedOut;

  /// Called after the user edits their name/avatar, so main.dart can update
  /// the AppUser it hands down (widget.me here doesn't rebuild on its own).
  final ValueChanged<AppUser> onProfileUpdated;

  /// Last-known-good group data, shown when a load fails. Null disables
  /// the offline fallback entirely (widget tests, mostly).
  final OfflineCache? cache;

  /// Test seam: supplies the group rows without an SDK or a server.
  @visibleForTesting
  final Future<List<GroupRow>> Function()? loadOverride;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final Loadable<List<GroupRow>> _rows = Loadable(widget.loadOverride ?? _fetchRows);

  /// True while the list on screen came from the cache rather than the
  /// server. Drives the banner — the user must never mistake stale data
  /// for live data.
  bool _showingCached = false;

  @override
  void initState() {
    super.initState();
    _rows.load();
  }

  @override
  void dispose() {
    _rows.dispose();
    super.dispose();
  }

  /// One group's row, or null to skip it (e.g. our membership hasn't
  /// propagated yet, or the group's data failed to load) — a single bad
  /// group no longer takes down the whole list.
  Future<GroupRow?> _loadRow(Group group) async {
    try {
      final members = await widget.sdk!.groups.listMembers(group.id);
      final me = memberFor(members, widget.me.id);
      if (me == null) return null;
      final balances = await widget.sdk!.balances.getBalances(group.id);
      final myBalances = balances.where((b) => b.memberId == me.id);
      final myNetCents = myBalances.isEmpty ? 0 : myBalances.first.netCents;
      final directName = group.isDirect ? directPersonName(members, widget.me, group.name) : '';
      final directAvatarUrl = group.isDirect
          ? (otherMember(members, widget.me)?.avatarUrl ?? '')
          : '';
      return GroupRow(group, me.id, myNetCents, members.length, directName, directAvatarUrl);
    } catch (_) {
      return null;
    }
  }

  Future<List<GroupRow>> _fetchRows() async {
    try {
      final groups = await widget.sdk!.groups.listMyGroups();
      final loaded = await Future.wait(groups.map(_loadRow));
      final rows = [
        for (final r in loaded)
          if (r != null) r,
      ];
      await widget.cache?.putGroups([
        for (final r in rows)
          GroupSummary(
            id: r.group.id,
            name: r.group.name,
            currency: r.group.currency,
            myNetCents: r.myNetCents,
            memberCount: r.memberCount,
          ),
      ]);
      await widget.cache?.markUpdated();
      _showingCached = false;
      return rows;
    } catch (_) {
      final cached = widget.cache?.groups();
      // Nothing to fall back to: the error is the honest answer, and
      // AsyncSection turns it into a retry.
      if (cached == null) rethrow;
      _showingCached = true;
      return [for (final g in cached) GroupRow.fromCache(g)];
    }
  }

  Future<void> _load() => _rows.load();

  void _refresh() {
    if (mounted) _load();
  }

  Map<String, int> _netByCurrency(List<GroupRow> rows) {
    final totals = <String, int>{};
    for (final r in rows) {
      totals[r.group.currency] = (totals[r.group.currency] ?? 0) + r.myNetCents;
    }
    return totals;
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    return Scaffold(
      body: SafeArea(
        child: AsyncSection<List<GroupRow>>(
          loadable: _rows,
          errorLabel: "Couldn't load your groups.",
          skeleton: const SkeletonList(),
          builder: (context, rows) {
            final totals = _netByCurrency(rows);
            return PageBody(
              child: Stack(
                children: [
                  Column(
                    children: [
                      if (_showingCached) _OfflineBanner(cache: widget.cache, onRetry: _load),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('SlicePay', style: pageTitleStyle(slice.ink)),
                            Row(
                              children: [
                                IconButton(
                                  tooltip: 'Activity',
                                  icon: Icon(Icons.receipt_long_outlined, color: slice.ink),
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ActivityScreen(sdk: widget.sdk, me: widget.me),
                                    ),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => _showAccountSheet(context),
                                  child: Avatar(
                                    meInitial(widget.me),
                                    imageUrl: widget.me.avatarUrl,
                                    background: slice.ink,
                                    foreground: slice.paper,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (totals.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: slice.border)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('OVERALL', style: sectionLabelStyle(slice.muted)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 20,
                                runSpacing: 8,
                                children: [
                                  for (final entry in totals.entries)
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        MoneyText(entry.value, entry.key, size: 28),
                                        const SizedBox(height: 2),
                                        Text(
                                          entry.value >= 0 ? 'owed to you' : 'you owe',
                                          style: TextStyle(fontSize: 12, color: slice.muted),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _load,
                          child: rows.isEmpty
                              ? ListView(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    const SizedBox(height: 120),
                                    Center(
                                      child: Text(
                                        'No groups yet',
                                        style: TextStyle(color: slice.muted),
                                      ),
                                    ),
                                  ],
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.only(bottom: 100),
                                  itemCount: rows.length,
                                  itemBuilder: (context, i) => _GroupTile(
                                    row: rows[i],
                                    onTap: () async {
                                      await Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => GroupDetailScreen(
                                            sdk: widget.sdk,
                                            me: widget.me,
                                            group: rows[i].group,
                                          ),
                                        ),
                                      );
                                      _refresh();
                                    },
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 24,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            await _showAddPersonSheet(context);
                            _refresh();
                          },
                          icon: Icon(Icons.person_add_alt_1, color: slice.ink),
                          label: const Text('Add person'),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.icon(
                          onPressed: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => NewGroupScreen(sdk: widget.sdk!)),
                            );
                            _refresh();
                          },
                          icon: Icon(Icons.add, color: slice.paper),
                          label: const Text('New group'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// "Add person" = a hidden 2-member group (Splitwise-style), so it reuses
  /// every existing expense/settle/balance flow — see createGroup(isDirect: true).
  Future<void> _showAddPersonSheet(BuildContext context) async {
    final nameController = TextEditingController();
    final emailController = TextEditingController();
    var currency = 'USD';
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Add person', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () async {
                  final picked = await pickCurrency(sheetContext, currency);
                  if (picked != null) setSheetState(() => currency = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Currency'),
                  child: Text('$currency  ${currencySymbol(currency)}'),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: const Text('Add'),
              ),
            ],
          ),
        ),
      ),
    );
    final personName = nameController.text.trim();
    final email = emailController.text.trim();
    nameController.dispose();
    emailController.dispose();
    if (confirmed != true || !context.mounted) return;
    if (personName.isEmpty || email.isEmpty) return;
    try {
      final group = await widget.sdk!.groups.createGroup(
        name: personName,
        currency: currency,
        isDirect: true,
      );
      await widget.sdk!.groups.inviteOrAddMember(groupId: group.id, email: email);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added $personName')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  void _showAccountSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Avatar(meInitial(widget.me), imageUrl: widget.me.avatarUrl, size: 40),
              title: Text(widget.me.name.isEmpty ? widget.me.email : widget.me.name),
              subtitle: widget.me.name.isEmpty ? null : Text(widget.me.email),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit profile'),
              onTap: () {
                Navigator.of(context).pop();
                _showEditProfileSheet(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Account settings'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(this.context).push(
                  MaterialPageRoute(
                    builder: (_) => AccountScreen(
                      sdk: widget.sdk,
                      me: widget.me,
                      groups: [for (final r in _rows.value ?? const <GroupRow>[]) r.group],
                      onSignedOut: widget.onSignedOut,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () {
                Navigator.of(context).pop();
                widget.onSignedOut();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditProfileSheet(BuildContext context) async {
    final nameController = TextEditingController(text: widget.me.name);
    Uint8List? pickedBytes;
    XFile? pickedFile;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Edit profile',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 16),
              Center(
                child: GestureDetector(
                  onTap: () async {
                    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
                    if (picked == null) return;
                    final bytes = await picked.readAsBytes();
                    setSheetState(() {
                      pickedFile = picked;
                      pickedBytes = bytes;
                    });
                  },
                  child: pickedBytes != null
                      ? CircleAvatar(radius: 40, backgroundImage: MemoryImage(pickedBytes!))
                      : Avatar(meInitial(widget.me), imageUrl: widget.me.avatarUrl, size: 80),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
    final newName = nameController.text.trim();
    nameController.dispose();
    if (saved != true || !context.mounted) return;
    try {
      final updated = await widget.sdk!.auth.updateProfile(
        name: newName.isEmpty ? null : newName,
        avatarBytes: pickedBytes,
        avatarFilename: pickedFile?.name,
      );
      widget.onProfileUpdated(updated);
      _refresh();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.row, required this.onTap});

  final GroupRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    final net = row.myNetCents;
    final isDirect = row.group.isDirect;
    final title = isDirect ? row.directName : row.group.name;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: slice.border)),
        ),
        child: Row(
          children: [
            Avatar(_initials(title), imageUrl: isDirect ? row.directAvatarUrl : null, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: slice.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isDirect
                        ? row.group.currency
                        : '${row.memberCount} people · ${row.group.currency}',
                    style: TextStyle(fontSize: 12.5, color: slice.muted),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                MoneyText(net, row.group.currency, size: 17),
                const SizedBox(height: 2),
                Text(
                  net >= 0 ? "you're owed" : 'you owe',
                  style: TextStyle(fontSize: 11, color: slice.muted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

/// Shown above the group list when the data on screen came from the cache.
/// Stale numbers must never be mistaken for live ones, so this says both
/// that the app is offline and how old the figures are.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.cache, required this.onRetry});

  final OfflineCache? cache;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    final updated = cache?.lastUpdated;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      color: slice.chip,
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: slice.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              updated == null
                  ? "You're offline — showing saved data."
                  : "You're offline — showing data from ${formatRelative(updated)}.",
              style: TextStyle(fontSize: 12.5, color: slice.ink),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
