// 1b — Group detail: member balances + expense list. Add expense / Settle
// up live as the two bottom actions, matching the design's card.
import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../activity.dart';
import '../display_name.dart';
import '../money.dart';
import '../theme.dart';
import '../widgets/money_text.dart';
import 'add_expense.dart';
import 'receipt_viewer.dart';
import 'settle_up.dart';

class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({super.key, required this.sdk, required this.me, required this.group});

  final SplitcoreSdk sdk;
  final AppUser me;
  final Group group;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  late Future<_GroupData> _data = _load();

  Future<_GroupData> _load() async {
    final members = await widget.sdk.groups.listMembers(widget.group.id);
    final balances = await widget.sdk.balances.getBalances(widget.group.id);
    final expenses = await widget.sdk.expenses.listExpenses(widget.group.id);
    final settlements = await widget.sdk.settlements.listSettlements(widget.group.id);
    final activity = buildActivity(
      group: widget.group,
      members: members,
      me: widget.me,
      expenses: expenses,
      settlements: settlements,
    );
    return _GroupData(members, balances, activity);
  }

  void _refresh() => setState(() {
        _data = _load();
      });

  Future<void> _openReceiptIfAny(BuildContext context, Expense expense) async {
    final entries = await widget.sdk.expenses.listSplitEntries(expense.id);
    final withReceipt = entries.where((e) => e.receiptFilename != null);
    if (withReceipt.isEmpty) return;
    final url = widget.sdk.expenses.receiptUrl(withReceipt.first);
    if (url == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReceiptViewerScreen(
        imageUrl: url,
        description: expense.description,
        amountCents: expense.amountCents,
        currency: widget.group.currency,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        actions: [
          IconButton(
            tooltip: 'Add member',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: () => _showAddMemberSheet(context),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: slice.chip, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  '${widget.group.currency} · ${currencySymbol(widget.group.currency).trim()}',
                  style: moneyStyle(size: 11, color: slice.ink),
                ),
              ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<_GroupData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load group: ${snapshot.error}'));
          }
          final data = snapshot.data!;
          final title = widget.group.isDirect
              ? directPersonName(data.members, widget.me, widget.group.name)
              : widget.group.name;
          return Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: slice.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          data.members.map((m) => displayName(m, widget.me)).join(', '),
                          style: TextStyle(fontSize: 12.5, color: slice.muted),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                    padding: EdgeInsets.zero,
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: slice.border)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        children: [
                          for (final member in data.members)
                            Expanded(
                              child: Container(
                                margin: const EdgeInsets.only(right: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: slice.card,
                                  border: Border.all(color: slice.border),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName(member, widget.me),
                                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: slice.ink),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 3),
                                    MoneyText(data.netFor(member.id), widget.group.currency, size: 16),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: data.activity.isEmpty
                        ? Center(child: Text('No activity yet', style: TextStyle(color: slice.muted)))
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 100),
                            itemCount: data.activity.length,
                            itemBuilder: (context, i) {
                              final item = data.activity[i];
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
                                  child: Icon(isSettlement ? Icons.swap_horiz : Icons.receipt_long, size: 18, color: slice.muted),
                                ),
                                title: Text(item.title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: slice.ink)),
                                subtitle: Text(item.subtitle, style: TextStyle(fontSize: 12, color: slice.muted)),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    MoneyText(item.amountCents, widget.group.currency, signed: false, size: 15),
                                  ],
                                ),
                                onTap: item.expense == null ? null : () => _openReceiptIfAny(context, item.expense!),
                              );
                            },
                          ),
                  ),
                ],
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 24,
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => AddExpenseScreen(
                              sdk: widget.sdk,
                              group: widget.group,
                              members: data.members,
                              me: widget.me,
                            ),
                          ));
                          _refresh();
                        },
                        icon: Icon(Icons.add, color: slice.paper),
                        label: const Text('Add expense'),
                        style: FilledButton.styleFrom(
                          backgroundColor: slice.ink,
                          foregroundColor: slice.paper,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => SettleUpScreen(
                              sdk: widget.sdk,
                              group: widget.group,
                              members: data.members,
                              balances: data.balances,
                              me: widget.me,
                            ),
                          ));
                          _refresh();
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: slice.ink,
                          side: BorderSide(color: slice.ink, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        ),
                        child: const Text('Settle up'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showAddMemberSheet(BuildContext context) async {
    final emailController = TextEditingController();
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
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
            const Text('Add member', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 12),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(sheetContext).pop(emailController.text.trim()),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (result == null || result.isEmpty || !context.mounted) return;
    try {
      final added = await widget.sdk.groups.inviteOrAddMember(groupId: widget.group.id, email: result);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(added ? 'Added to the group' : "Invited — they'll join once they sign up"),
      ));
      _refresh();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}

class _GroupData {
  _GroupData(this.members, this.balances, this.activity);
  final List<GroupMember> members;
  final List<Balance> balances;
  final List<ActivityItem> activity;

  int netFor(String memberId) {
    final matches = balances.where((b) => b.memberId == memberId);
    return matches.isEmpty ? 0 : matches.first.netCents;
  }
}
