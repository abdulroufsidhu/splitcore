// 1a — Home: groups & balances. The groups list *is* the app (no tab bar);
// account/sign-out lives behind the header avatar.
import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/money_text.dart';
import 'group_detail.dart';
import 'new_group.dart';

/// One row's worth of data: the group plus *my* net balance within it.
class _GroupRow {
  _GroupRow(this.group, this.myMemberId, this.myNetCents, this.memberCount);
  final Group group;
  final String myMemberId;
  final int myNetCents;
  final int memberCount;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.sdk, required this.me, required this.onSignedOut});

  final SplitcoreSdk sdk;
  final AppUser me;
  final VoidCallback onSignedOut;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<_GroupRow>> _rows = _load();

  Future<List<_GroupRow>> _load() async {
    final groups = await widget.sdk.groups.listMyGroups();
    final rows = <_GroupRow>[];
    for (final group in groups) {
      final members = await widget.sdk.groups.listMembers(group.id);
      final me = members.firstWhere((m) => m.userId == widget.me.id);
      final balances = await widget.sdk.balances.getBalances(group.id);
      final myBalances = balances.where((b) => b.memberId == me.id);
      final myNetCents = myBalances.isEmpty ? 0 : myBalances.first.netCents;
      rows.add(_GroupRow(group, me.id, myNetCents, members.length));
    }
    return rows;
  }

  void _refresh() => setState(() => _rows = _load());

  Map<String, int> _netByCurrency(List<_GroupRow> rows) {
    final totals = <String, int>{};
    for (final r in rows) {
      totals[r.group.currency] = (totals[r.group.currency] ?? 0) + r.myNetCents;
    }
    return totals;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<List<_GroupRow>>(
          future: _rows,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load groups: ${snapshot.error}'));
            }
            final rows = snapshot.data!;
            final totals = _netByCurrency(rows);
            return Stack(
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'SlicePay',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                              color: SliceColors.ink,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => _showAccountSheet(context),
                            child: Avatar(
                              widget.me.email.isNotEmpty ? widget.me.email[0].toUpperCase() : '?',
                              background: SliceColors.ink,
                              foreground: SliceColors.paper,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (totals.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: SliceColors.border)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'OVERALL',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.2,
                                color: SliceColors.muted,
                              ),
                            ),
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
                                        style: const TextStyle(fontSize: 12, color: SliceColors.muted),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: rows.isEmpty
                          ? const Center(child: Text('No groups yet', style: TextStyle(color: SliceColors.muted)))
                          : ListView.builder(
                              itemCount: rows.length,
                              itemBuilder: (context, i) => _GroupTile(
                                row: rows[i],
                                onTap: () async {
                                  await Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => GroupDetailScreen(
                                      sdk: widget.sdk,
                                      me: widget.me,
                                      group: rows[i].group,
                                    ),
                                  ));
                                  _refresh();
                                },
                              ),
                            ),
                    ),
                  ],
                ),
                Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: FilledButton.icon(
                      onPressed: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => NewGroupScreen(sdk: widget.sdk),
                        ));
                        _refresh();
                      },
                      icon: const Icon(Icons.add, color: SliceColors.paper),
                      label: const Text('New group'),
                      style: FilledButton.styleFrom(
                        backgroundColor: SliceColors.ink,
                        foregroundColor: SliceColors.paper,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showAccountSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(widget.me.email)),
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
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.row, required this.onTap});

  final _GroupRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final net = row.myNetCents;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: SliceColors.border)),
        ),
        child: Row(
          children: [
            Avatar(_initials(row.group.name), size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.group.name,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: SliceColors.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${row.memberCount} people · ${row.group.currency}',
                    style: const TextStyle(fontSize: 12.5, color: SliceColors.muted),
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
                  style: const TextStyle(fontSize: 11, color: SliceColors.muted),
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
    if (parts.length == 1) return parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}
