// 1b — Group detail: member balances + expense list. Add expense / Settle
// up live as the two bottom actions, matching the design's card.
// Flutter's navigator also exports a `Page`; the SDK's paging type is the
// one this screen deals in.
import 'dart:async';

import 'package:flutter/material.dart' hide Page;
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../activity.dart';
import '../display_name.dart';
import '../loadable.dart';
import '../money.dart';
import '../theme.dart';
import '../widgets/async_section.dart';
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
  });

  final List<GroupMember> members;
  final List<Balance> balances;
  final Page<Expense> expenses;
  final Page<Settlement> settlements;

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
    this.loadMoreOverride,
    this.searchOverride,
  });

  /// Null only in widget tests, which supply [loadOverride] instead.
  final SplitcoreSdk? sdk;
  final AppUser me;
  final Group group;

  /// Test seam: supplies the screen's data without an SDK or a server.
  @visibleForTesting
  final Future<GroupDetailData> Function()? loadOverride;

  /// Test seam for the "show older expenses" path.
  @visibleForTesting
  final Future<Page<Expense>> Function(int page)? loadMoreOverride;

  /// Test seam for search.
  @visibleForTesting
  final Future<Page<Expense>> Function(String query)? searchOverride;

  @override
  State<GroupDetailScreen> createState() => GroupDetailScreenState();
}

class GroupDetailScreenState extends State<GroupDetailScreen> {
  late final Loadable<GroupDetailData> _data = Loadable(widget.loadOverride ?? _fetch);

  /// Pages appended past the first. Kept out of the Loadable's value so a
  /// refresh resets paging to page 1 — which is what "pull to refresh"
  /// should mean, rather than stacking a stale page under fresh data.
  final List<Expense> _extraExpenses = [];
  int _loadedPage = 1;
  bool _loadingMore = false;

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  /// Non-null while a search is showing; null means "show the normal
  /// activity list".
  List<Expense>? _searchResults;

  @override
  void initState() {
    super.initState();
    _data.load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _data.dispose();
    super.dispose();
  }

  /// Debounced because the search hits the server: firing per keystroke
  /// issues one request per character and lets a slow early response
  /// overwrite a later one.
  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      final search =
          widget.searchOverride ??
          (String q) => widget.sdk!.expenses.searchExpenses(widget.group.id, q);
      try {
        final results = await search(query);
        if (mounted) setState(() => _searchResults = results.items);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't search: $e")));
      }
    });
  }

  Future<GroupDetailData> _fetch() async {
    final sdk = widget.sdk!;
    final members = await sdk.groups.listMembers(widget.group.id);
    final balances = await sdk.balances.getBalances(widget.group.id);
    final expenses = await sdk.expenses.listExpenses(widget.group.id);
    final settlements = await sdk.settlements.listSettlements(widget.group.id);
    return GroupDetailData(
      members: members,
      balances: balances,
      expenses: expenses,
      settlements: settlements,
    );
  }

  /// Reloads from page 1, discarding any appended pages.
  Future<void> refresh() {
    _extraExpenses.clear();
    _loadedPage = 1;
    return _data.load();
  }

  void _refresh() {
    if (mounted) refresh();
  }

  Future<void> _loadMore(Page<Expense> current) async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final fetch =
          widget.loadMoreOverride ??
          (int page) => widget.sdk!.expenses.listExpenses(
            widget.group.id,
            page: page,
            perPage: current.perPage,
          );
      final next = await fetch(_loadedPage + 1);
      if (!mounted) return;
      setState(() {
        _extraExpenses.addAll(next.items);
        _loadedPage = next.page;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't load older expenses: $e")));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// True while the first page plus anything appended still does not cover
  /// every expense the server reported.
  bool _hasMoreExpenses(Page<Expense> page) =>
      page.items.length + _extraExpenses.length < page.totalItems;

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
              expenses: searching ? _searchResults! : [...data.expenses.items, ..._extraExpenses],
              settlements: searching ? const [] : data.settlements.items,
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
                                    Container(
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
                                          const SizedBox(height: 3),
                                          MoneyText(
                                            data.netFor(member.id),
                                            widget.group.currency,
                                            size: 16,
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
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
                                  // One extra row for the load-more
                                  // affordance when older pages exist.
                                  itemCount:
                                      activity.length +
                                      (!searching && _hasMoreExpenses(data.expenses) ? 1 : 0),
                                  itemBuilder: (context, i) {
                                    if (i == activity.length) {
                                      return _LoadMoreRow(
                                        remaining:
                                            data.expenses.totalItems -
                                            data.expenses.items.length -
                                            _extraExpenses.length,
                                        loading: _loadingMore,
                                        onPressed: () => _loadMore(data.expenses),
                                      );
                                    }
                                    final item = activity[i];
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

/// The "show older expenses" row at the foot of the activity list.
class _LoadMoreRow extends StatelessWidget {
  const _LoadMoreRow({required this.remaining, required this.loading, required this.onPressed});

  final int remaining;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: onPressed,
                child: Text(
                  remaining == 1 ? 'Show 1 older expense' : 'Show $remaining older expenses',
                ),
              ),
      ),
    );
  }
}
