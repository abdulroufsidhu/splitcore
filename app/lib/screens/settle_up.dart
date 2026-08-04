// 1d — Settle up: SplitcoreSdk.settleUp() suggests the minimal set of
// transfers; each "Record payment" writes one settlement (a reimbursement
// record, not a real money movement).
import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../display_name.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/money_text.dart';
import '../widgets/page_body.dart';
import '../widgets/skeleton.dart';

class SettleUpScreen extends StatefulWidget {
  const SettleUpScreen({
    super.key,
    required this.sdk,
    required this.group,
    required this.members,
    required this.balances,
    required this.me,
  });

  final SplitcoreSdk sdk;
  final Group group;
  final List<GroupMember> members;
  final List<Balance> balances;
  final AppUser me;

  @override
  State<SettleUpScreen> createState() => _SettleUpScreenState();
}

class _SettleUpScreenState extends State<SettleUpScreen> {
  late final Future<List<Transfer>> _transfers = widget.sdk.settleUp(widget.balances);
  final Set<int> _recorded = {};

  GroupMember? _member(String id) => memberFor(widget.members, id);

  Future<void> _record(int index, Transfer t) async {
    try {
      final group = await widget.sdk.groups.getGroup(widget.group.id);
      await widget.sdk.settlements.createSettlement(
        groupId: widget.group.id,
        localVersion: group.version,
        fromMemberId: t.fromMemberId,
        toMemberId: t.toMemberId,
        amountCents: t.amountCents,
      );
      setState(() => _recorded.add(index));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    return Scaffold(
      appBar: AppBar(leading: const BackButton()),
      body: SafeArea(
        child: FutureBuilder<List<Transfer>>(
          future: _transfers,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SkeletonList();
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to compute settlement: ${snapshot.error}'));
            }
            final transfers = snapshot.data!;
            return PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Settle ${widget.group.name}', style: sectionLabelStyle(slice.muted)),
                        const SizedBox(height: 8),
                        Text(
                          transfers.isEmpty
                              ? 'Already settled'
                              : '${transfers.length} payment${transfers.length == 1 ? '' : 's'}\nsettle everything',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.6,
                            color: slice.ink,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "The fewest possible transfers for this group's balances.",
                          style: TextStyle(fontSize: 13, color: slice.muted),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: transfers.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, i) {
                        final t = transfers[i];
                        final from = _member(t.fromMemberId);
                        final to = _member(t.toMemberId);
                        if (from == null || to == null) return const SizedBox.shrink();
                        final done = _recorded.contains(i);
                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: slice.card,
                            border: Border.all(color: slice.border),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Avatar(initialsFor(from, widget.me), size: 34),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: RichText(
                                      text: TextSpan(
                                        style: TextStyle(fontSize: 14.5, color: slice.ink),
                                        children: [
                                          TextSpan(
                                            text: displayName(from, widget.me),
                                            style: const TextStyle(fontWeight: FontWeight.w700),
                                          ),
                                          const TextSpan(text: ' pays '),
                                          TextSpan(
                                            text: displayName(to, widget.me),
                                            style: const TextStyle(fontWeight: FontWeight.w700),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  MoneyText(
                                    t.amountCents,
                                    widget.group.currency,
                                    signed: false,
                                    size: 22,
                                    weight: FontWeight.w700,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FilledButton(
                                  onPressed: done ? null : () => _record(i, t),
                                  style: FilledButton.styleFrom(backgroundColor: slice.positive),
                                  child: Text(done ? 'Recorded' : 'Record payment'),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
                    child: Text(
                      "Recording a payment updates everyone's balance.\nIt doesn't move money.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: slice.muted),
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
}
