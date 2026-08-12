// 1b — Group detail: member balances + expense list. Add expense / Settle
// up live as the two bottom actions, matching the design's card.
//
// Every read here comes from the SDK's local database, so the screen
// renders offline and re-renders when a sync writes. That also retired the
// paging: local rows have no request to economise on, and "show older
// expenses" was only ever working around one.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../activity.dart';
import '../display_name.dart';
import '../loadable.dart';
import '../money.dart';
import '../theme.dart';
import '../widgets/async_section.dart';
import '../widgets/avatar.dart';
import '../widgets/money_text.dart';
import '../widgets/page_body.dart';
import '../widgets/skeleton.dart';
import 'add_expense.dart';
import 'receipt_viewer.dart';
import 'settle_up.dart';

/// Everything the group detail screen needs, fetched as one unit. Public so
/// a widget test can construct it without an SDK or a server.
class GroupDetailData {
  const GroupDetailData({
    required this.members,
    required this.balances,
    required this.expenses,
    required this.settlements,
    this.formerMembers = const [],
  });

  /// The group's current members.
  final List<GroupMember> members;

  /// People the owner has removed whose rows had to be kept, because their
  /// expenses and everyone's balances reference them. Shown as a muted line
  /// so a removal is legible rather than a silent disappearance.
  final List<GroupMember> formerMembers;
  final List<Balance> balances;
  final List<Expense> expenses;
  final List<Settlement> settlements;

  int netFor(String memberId) {
    final matches = balances.where((b) => b.memberId == memberId);
    return matches.isEmpty ? 0 : matches.first.netCents;
  }
}

class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({
    super.key,
    required this.sdk,
    required this.me,
    required this.group,
    this.loadOverride,
    this.searchOverride,
    this.removeMemberOverride,
    this.unsentCountOverride,
  });

  /// Null only in widget tests, which supply [loadOverride] instead.
  final SplitcoreSdk? sdk;

  /// Test seam for the removal call, so a test can drive the sheet's rules
  /// without an SDK. Returns the server's status, as
  /// [GroupsRepository.removeMember] does.
  @visibleForTesting
  final Future<String> Function(String memberId)? removeMemberOverride;

  /// Test seam for "how much work has not reached the server yet".
  @visibleForTesting
  final Future<int> Function()? unsentCountOverride;
  final AppUser me;
  final Group group;

  /// Test seam: supplies the screen's data without an SDK or a server.
  @visibleForTesting
  final Future<GroupDetailData> Function()? loadOverride;

  /// Test seam for search.
  @visibleForTesting
  final Future<List<Expense>> Function(String query)? searchOverride;

  @override
  State<GroupDetailScreen> createState() => GroupDetailScreenState();
}

class GroupDetailScreenState extends State<GroupDetailScreen> {
  late final Loadable<GroupDetailData> _data = Loadable(widget.loadOverride ?? _fetch);

  final TextEditingController _searchController = TextEditingController();
  StreamSubscription<List<Expense>>? _expensesSub;
  Timer? _searchDebounce;

  /// Non-null while a search is showing; null means "show the normal
  /// activity list".
  List<Expense>? _searchResults;

  @override
  void initState() {
    super.initState();
    _data.load();
    // A sync (or another screen's write) commits to the local database;
    // this is how an open group screen finds out, instead of showing
    // yesterday's expenses until the user navigates away and back.
    _expensesSub = widget.sdk?.expenses.watch(widget.group.id).skip(1).listen((_) => _refresh());
  }

  @override
  void dispose() {
    unawaited(_expensesSub?.cancel());
    _searchDebounce?.cancel();
    _searchController.dispose();
    _data.dispose();
    super.dispose();
  }

  /// Still debounced, though the query is now a local SQLite scan rather
  /// than a request: re-querying and rebuilding the list on every keystroke
  /// is wasted work on a long history.
  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      final search =
          widget.searchOverride ??
          (String q) => widget.sdk!.expenses.listExpenses(widget.group.id, query: q);
      try {
        final results = await search(query);
        if (mounted) setState(() => _searchResults = results);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't search: $e")));
      }
    });
  }

  Future<GroupDetailData> _fetch() async {
    final sdk = widget.sdk!;
    final members = await sdk.groups.listMembers(widget.group.id);
    final everyone = await sdk.groups.listAllMembers(widget.group.id);
    final balances = await sdk.balances.get(widget.group.id);
    final expenses = await sdk.expenses.listExpenses(widget.group.id);
    final settlements = await sdk.settlements.listSettlements(widget.group.id);
    return GroupDetailData(
      members: members,
      formerMembers: [
        for (final m in everyone)
          if (!m.isActive) m,
      ],
      balances: balances,
      expenses: expenses,
      settlements: settlements,
    );
  }

  Future<void> refresh() => _data.load();

  /// Pull-to-refresh asks the sync engine for a pull; the resulting local
  /// write arrives back through _expensesSub.
  Future<void> refreshFromServer() async {
    await widget.sdk?.sync.now();
    await refresh();
  }

  void _refresh() {
    if (mounted) refresh();
  }

  Future<void> _openReceiptIfAny(BuildContext context, Expense expense) async {
    final entries = await widget.sdk!.expenses.listSplitEntries(expense.id);
    final withReceipt = entries.where((e) => e.receiptFilename != null);
    if (withReceipt.isEmpty) return;
    final url = widget.sdk!.expenses.receiptUrl(withReceipt.first);
    if (url == null || !context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReceiptViewerScreen(
          imageUrl: url,
          description: expense.description,
          amountCents: expense.amountCents,
          currency: widget.group.currency,
        ),
      ),
    );
  }

  /// Edit / delete for one expense. A sheet rather than a swipe: swipe-to-
  /// delete has no confirmation on the way in and the gesture fights the
  /// scroll axis.
  Future<void> _showExpenseActions(
    BuildContext context,
    Expense expense,
    List<GroupMember> members,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit expense'),
              onTap: () => Navigator.of(sheetContext).pop('edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text(
                'Delete expense',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'edit') await _editExpense(expense, members);
    if (action == 'delete') await _deleteExpense(expense);
  }

  Future<void> _editExpense(Expense expense, List<GroupMember> members) async {
    final splits = await widget.sdk!.expenses.listSplitEntries(expense.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddExpenseScreen(
          sdk: widget.sdk,
          group: widget.group,
          members: members,
          me: widget.me,
          existing: expense,
          existingSplits: splits,
        ),
      ),
    );
    _refresh();
  }

  Future<void> _deleteExpense(Expense expense) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this expense?'),
        // Deleting rewrites every member's balance, so it is never a
        // single unconfirmed tap.
        content: Text(
          '"${expense.description}" will be removed and everyone\'s balances '
          'will be recalculated. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.sdk!.expenses.deleteExpense(expense.id);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't delete: $e")));
    }
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
                decoration: BoxDecoration(
                  color: slice.chip,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${widget.group.currency} · ${currencySymbol(widget.group.currency).trim()}',
                  style: moneyStyle(size: 11, color: slice.ink),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: AsyncSection<GroupDetailData>(
          loadable: _data,
          errorLabel: "Couldn't load this group.",
          skeleton: const SkeletonList(),
          builder: (context, data) {
            final title = widget.group.isDirect
                ? directPersonName(data.members, widget.me, widget.group.name)
                : widget.group.name;
            // Derived here rather than stored, so appended pages show up
            // without another round trip.
            final searching = _searchResults != null;
            final activity = buildActivity(
              group: widget.group,
              members: data.members,
              me: widget.me,
              // While searching, the list shows matches only — settlements
              // are not searchable, so they drop out with them.
              expenses: searching ? _searchResults! : data.expenses,
              settlements: searching ? const [] : data.settlements,
            );
            return RefreshIndicator(
              onRefresh: refresh,
              child: PageBody(
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: pageTitleStyle(slice.ink, size: 24)),
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
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final member in data.members)
                                    GestureDetector(
                                      onTap: () => _showMemberSheet(member, data),
                                      child: Container(
                                        width: 120,
                                        margin: const EdgeInsets.only(right: 8),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
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
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w600,
                                                color: slice.ink,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            // Rendered for everyone, blank for
                                            // members, so every card keeps the
                                            // same height — a Row lays its
                                            // children out at their own heights,
                                            // and one taller card would leave the
                                            // rest visibly misaligned.
                                            Text(
                                              member.userId == widget.group.ownerId ? 'OWNER' : '',
                                              style: TextStyle(
                                                fontSize: 9,
                                                letterSpacing: 0.6,
                                                fontWeight: FontWeight.w700,
                                                color: slice.muted,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            MoneyText(
                                              data.netFor(member.id),
                                              widget.group.currency,
                                              size: 16,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (data.formerMembers.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                            child: Text(
                              'Former members: '
                              '${data.formerMembers.map((m) => displayName(m, widget.me)).join(', ')}',
                              style: TextStyle(fontSize: 12, color: slice.muted),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: TextField(
                            controller: _searchController,
                            onChanged: _onSearchChanged,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Search expenses',
                              prefixIcon: const Icon(Icons.search, size: 20),
                              suffixIcon: searching
                                  ? IconButton(
                                      tooltip: 'Clear search',
                                      icon: const Icon(Icons.close, size: 18),
                                      onPressed: () {
                                        _searchController.clear();
                                        _onSearchChanged('');
                                      },
                                    )
                                  : null,
                            ),
                          ),
                        ),
                        Expanded(
                          child: activity.isEmpty
                              ? Center(
                                  child: Text(
                                    searching ? 'No expenses match.' : 'No activity yet',
                                    style: TextStyle(color: slice.muted),
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.only(bottom: 100),
                                  itemCount: activity.length,
                                  itemBuilder: (context, i) {
                                    final item = activity[i];
                                    final isSettlement = item.kind == ActivityKind.settlement;
                                    // Unsent: the figures are real and local,
                                    // but nobody else can see them yet. Faded
                                    // rather than hidden — the user made this
                                    // entry and must still find it.
                                    final unsent = item.expense?.pending ?? false;
                                    return Opacity(
                                      opacity: unsent ? 0.55 : 1,
                                      child: ListTile(
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
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                            color: slice.ink,
                                          ),
                                        ),
                                        subtitle: Text(
                                          item.subtitle,
                                          style: TextStyle(fontSize: 12, color: slice.muted),
                                        ),
                                        trailing: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            MoneyText(
                                              item.amountCents,
                                              widget.group.currency,
                                              signed: false,
                                              size: 15,
                                            ),
                                          ],
                                        ),
                                        onTap: item.expense == null
                                            ? null
                                            : () => _openReceiptIfAny(context, item.expense!),
                                        onLongPress: item.expense == null
                                            ? null
                                            : () => _showExpenseActions(
                                                context,
                                                item.expense!,
                                                data.members,
                                              ),
                                      ),
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
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => AddExpenseScreen(
                                      sdk: widget.sdk!,
                                      group: widget.group,
                                      members: data.members,
                                      me: widget.me,
                                    ),
                                  ),
                                );
                                _refresh();
                              },
                              icon: Icon(Icons.add, color: slice.paper),
                              label: const Text('Add expense'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => SettleUpScreen(
                                      sdk: widget.sdk!,
                                      group: widget.group,
                                      members: data.members,
                                      balances: data.balances,
                                      me: widget.me,
                                    ),
                                  ),
                                );
                                _refresh();
                              },
                              child: const Text('Settle up'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The member sheet: who they are, what they owe, and the way out of the
  /// group — "Remove from group" for the owner acting on somebody else,
  /// "Leave group" for anyone acting on themselves. Both are the same
  /// operation on the same row, under the same rules; only the wording and
  /// who may ask differ.
  ///
  /// The rules live in the button's state rather than in an error the user
  /// only sees after tapping: you can only act on yourself unless you own
  /// the group, the group's owner can do neither, unsent work blocks
  /// everything, and an unsettled balance blocks the rest. The server
  /// enforces all of it regardless (server/hooks/remove_member.go) — this is
  /// so the user knows where they stand before acting.
  Future<void> _showMemberSheet(GroupMember member, GroupDetailData data) async {
    final slice = context.slice;
    final net = data.netFor(member.id);
    final iAmOwner = widget.group.ownerId == widget.me.id;
    final isGroupOwner = member.userId == widget.group.ownerId;
    final isMe = member.userId == widget.me.id;
    final name = displayName(member, widget.me);
    final unsent = await _unsentCount();
    if (!mounted) return;

    // Unsent work outranks the balance, because it is what makes the
    // balance untrustworthy: the server judges a removal on what it can
    // see, and anything still queued is invisible to it.
    final String? blocked = switch ((isGroupOwner, iAmOwner || isMe, unsent, net)) {
      (true, _, _, _) when isMe =>
        "You own this group, so you can't leave it. Hand it over or delete it instead.",
      (true, _, _, _) => "The group's owner can't be removed.",
      (_, false, _, _) => 'Only the group owner can remove other members.',
      (_, _, final u, _) when u > 0 =>
        u == 1
            ? "1 change hasn't reached the server yet. Nobody can leave or be removed "
                  'until it syncs — doing so now could discard that change.'
            : "$u changes haven't reached the server yet. Nobody can leave or be "
                  'removed until they sync — doing so now could discard them.',
      (_, _, _, final n) when n != 0 =>
        isMe
            ? "You have an unsettled balance in this group. Settle up before leaving."
            : '$name has an unsettled balance. Settle up before removing them.',
      _ => null,
    };
    final actionLabel = isMe ? 'Leave group' : 'Remove from group';

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Avatar(
                    initialsFor(member, widget.me),
                    imageUrl: member.avatarUrl,
                    size: 44,
                    background: slice.ink,
                    foreground: slice.paper,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                        ),
                        Text(
                          isGroupOwner ? 'Owner' : 'Member',
                          style: TextStyle(fontSize: 12, color: slice.muted),
                        ),
                      ],
                    ),
                  ),
                  MoneyText(net, widget.group.currency, size: 18),
                ],
              ),
              const SizedBox(height: 20),
              if (blocked != null)
                Text(blocked, style: TextStyle(fontSize: 12.5, color: slice.muted))
              else
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: slice.negative),
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  child: Text(actionLabel),
                ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    // Neither is undoable from here — getting back in means being invited
    // again — so both get a confirmation of their own.
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isMe ? 'Leave ${widget.group.name}?' : 'Remove $name?'),
        content: Text(
          isMe
              ? "You'll be taken out of ${widget.group.name}. Any expenses you're "
                    'already part of stay in the group, so nobody else’s balance '
                    "changes. You'll need an invite to rejoin."
              : "They'll be taken out of ${widget.group.name}. Any expenses they're "
                    'already part of stay in the group, so nobody else’s balance changes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isMe ? 'Leave' : 'Remove', style: TextStyle(color: slice.negative)),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    try {
      final remove = widget.removeMemberOverride ?? widget.sdk!.groups.removeMember;
      final status = await remove(member.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch ((isMe, status)) {
            (true, 'deactivated') =>
              "You left ${widget.group.name} — your past expenses stay in its history.",
            (true, _) => 'You left ${widget.group.name}.',
            (_, 'deactivated') =>
              "$name removed — their past expenses stay in this group's history.",
            _ => '$name removed.',
          }),
        ),
      );
      // Leaving means this screen is showing a group we are no longer in.
      if (isMe) {
        Navigator.of(context).pop();
        return;
      }
      await refresh();
    } on UnsyncedWritesException catch (e) {
      // The queue can fill up between opening the sheet and confirming, so
      // the check above is a courtesy and this is the real gate.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "${e.count} change(s) still haven't reached the server. "
            '${isMe ? 'You did not leave' : '$name was not removed'} — try again '
            'once everything has synced.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't ${isMe ? 'leave' : 'remove'}: $e")));
    }
  }

  /// Work the server has not seen yet and still might: queued writes, plus
  /// edits parked on a conflict, which replay if the user keeps their
  /// version. Ops the server already rejected are excluded — nothing
  /// replays them, so they cannot affect a removal.
  Future<int> _unsentCount() async {
    final override = widget.unsentCountOverride;
    if (override != null) return override();
    final sync = widget.sdk?.sync;
    if (sync == null) return 0;
    return (await sync.queued()).length + (await sync.conflicts()).length;
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
    emailController.dispose();
    if (result == null || result.isEmpty || !context.mounted) return;
    try {
      final added = await widget.sdk!.groups.inviteOrAddMember(
        groupId: widget.group.id,
        email: result,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(added ? 'Added to the group' : "Invited — they'll join once they sign up"),
        ),
      );
      _refresh();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}
