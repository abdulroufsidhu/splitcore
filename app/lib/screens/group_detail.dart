// 1b — Group detail: member balances + expense list. Add expense / Settle
// up live as the two bottom actions, matching the design's card.
import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

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
    return _GroupData(members, balances, expenses);
  }

  void _refresh() => setState(() => _data = _load());

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
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: SliceColors.chip, borderRadius: BorderRadius.circular(6)),
                child: Text(
                  '${widget.group.currency} · ${currencySymbol(widget.group.currency).trim()}',
                  style: moneyStyle(size: 11),
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
                          widget.group.name,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: SliceColors.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          data.members.map((m) => displayName(m, widget.me)).join(', '),
                          style: const TextStyle(fontSize: 12.5, color: SliceColors.muted),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                    padding: EdgeInsets.zero,
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: SliceColors.border)),
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
                                  color: SliceColors.card,
                                  border: Border.all(color: SliceColors.border),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName(member, widget.me),
                                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: SliceColors.ink),
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
                    child: data.expenses.isEmpty
                        ? const Center(child: Text('No expenses yet', style: TextStyle(color: SliceColors.muted)))
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 100),
                            itemCount: data.expenses.length,
                            itemBuilder: (context, i) {
                              final e = data.expenses[i];
                              final payer = data.members.firstWhere((m) => m.id == e.payerMemberId);
                              return ListTile(
                                leading: Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: SliceColors.card,
                                    border: Border.all(color: SliceColors.border),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(Icons.receipt_long, size: 18, color: SliceColors.muted),
                                ),
                                title: Text(e.description, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                subtitle: Text(
                                  '${displayName(payer, widget.me)} paid · split ${e.splitType}',
                                  style: const TextStyle(fontSize: 12, color: SliceColors.muted),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    MoneyText(e.amountCents, widget.group.currency, signed: false, size: 15),
                                  ],
                                ),
                                onTap: () => _openReceiptIfAny(context, e),
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
                        icon: const Icon(Icons.add, color: SliceColors.paper),
                        label: const Text('Add expense'),
                        style: FilledButton.styleFrom(
                          backgroundColor: SliceColors.ink,
                          foregroundColor: SliceColors.paper,
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
                          foregroundColor: SliceColors.ink,
                          side: const BorderSide(color: SliceColors.ink, width: 1.5),
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
}

class _GroupData {
  _GroupData(this.members, this.balances, this.expenses);
  final List<GroupMember> members;
  final List<Balance> balances;
  final List<Expense> expenses;

  int netFor(String memberId) {
    final matches = balances.where((b) => b.memberId == memberId);
    return matches.isEmpty ? 0 : matches.first.netCents;
  }
}
