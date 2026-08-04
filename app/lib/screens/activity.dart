// Global activity feed: every expense + settlement across all of the
// user's groups, newest first. Reuses buildActivity per group (same
// merge helper the group-detail inline list uses) and just concatenates.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../activity.dart';
import '../theme.dart';
import '../widgets/money_text.dart';
import '../widgets/page_body.dart';
import '../widgets/skeleton.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.sdk, required this.me});

  final SplitcoreSdk sdk;
  final AppUser me;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  late final Future<List<ActivityItem>> _items = _load();

  // ponytail: N+1 over groups (one round trip per group); fine at personal
  // scale, add a server-side aggregate endpoint if group counts grow.
  Future<List<ActivityItem>> _load() async {
    final groups = await widget.sdk.groups.listMyGroups();
    final items = <ActivityItem>[];
    for (final group in groups) {
      final members = await widget.sdk.groups.listMembers(group.id);
      // The global feed genuinely wants every row per group, not a page.
      final expenses = await widget.sdk.expenses.listAllExpenses(group.id);
      final settlements = await widget.sdk.settlements.listAllSettlements(group.id);
      items.addAll(
        buildActivity(
          group: group,
          members: members,
          me: widget.me,
          expenses: expenses,
          settlements: settlements,
        ),
      );
    }
    items.sort((a, b) => b.date.compareTo(a.date));
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text('Activity')),
      body: SafeArea(
        child: FutureBuilder<List<ActivityItem>>(
          future: _items,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SkeletonList();
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load activity: ${snapshot.error}'));
            }
            final items = snapshot.data!;
            if (items.isEmpty) {
              return Center(
                child: Text('No activity yet', style: TextStyle(color: slice.muted)),
              );
            }
            return PageBody(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  final isSettlement = item.kind == ActivityKind.settlement;
                  return ListTile(
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: slice.card,
                        border: Border.all(color: slice.border),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        isSettlement ? Icons.swap_horiz : Icons.receipt_long,
                        size: 18,
                        color: slice.muted,
                      ),
                    ),
                    title: Text(
                      item.title,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: slice.ink),
                    ),
                    subtitle: Text(
                      '${item.groupName} · ${item.subtitle} · ${DateFormat.yMMMd().format(item.date)}',
                      style: TextStyle(fontSize: 12, color: slice.muted),
                    ),
                    trailing: MoneyText(item.amountCents, item.currency, signed: false, size: 15),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
