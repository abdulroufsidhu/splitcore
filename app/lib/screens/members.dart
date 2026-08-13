// The group's members as a plain list, which the balance cards on the group
// screen are not: they are a horizontal strip you scroll past, sized to show
// money rather than to manage people. Removing somebody meant finding their
// card, and leaving a group meant tapping your own — this is where both are
// spelled out.
//
// The screen owns no data. It renders the group screen's [Loadable] and
// calls back for everything, so a removal here refreshes the ledger
// underneath and this list rebuilds from the same value.
import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../display_name.dart';
import '../layout.dart';
import '../loadable.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/money_text.dart';
import '../widgets/page_body.dart';
import 'group_detail.dart';

class MembersScreen extends StatefulWidget {
  const MembersScreen({
    super.key,
    required this.data,
    required this.group,
    required this.me,
    required this.canManage,
    required this.onOpenMember,
    required this.onRemove,
  });

  /// The group screen's own loadable, listened to rather than copied: a
  /// removal refreshes it and this list follows, instead of holding a
  /// snapshot that goes stale the moment it is acted on.
  final Loadable<GroupDetailData> data;

  final Group group;
  final AppUser me;

  /// Whether this user may remove other people — the group's owner. Everyone
  /// else gets the list and their own way out, and no selection mode.
  final bool canManage;

  /// Opens the group screen's member sheet, which owns the single-member
  /// actions (remove, leave, hand the group over).
  final void Function(GroupMember member) onOpenMember;

  /// Removes everyone named, confirming and reporting on the way. The rules
  /// and the messaging live with the single-member path on the group screen.
  final Future<void> Function(List<GroupMember> members) onRemove;

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  /// Member ids ticked in selection mode. Ids that stop existing (removed
  /// while selected) fall out when the list rebuilds — see [_selectable].
  final Set<String> _selected = {};
  bool _selecting = false;

  /// Why this member can't be ticked, or null if they can be.
  ///
  /// The full rules are the server's (server/hooks/remove_member.go); these
  /// are the two it is worth stating up front, so a row explains itself
  /// rather than failing after a tap. The unsent-work gate isn't here
  /// because it is a property of the queue, not of a member — the group
  /// screen checks it once, when the removal is asked for.
  String? _blockedReason(GroupMember member, GroupDetailData data) {
    if (member.userId == widget.group.ownerId) return "Owner — can't be removed";
    if (data.netFor(member.id) != 0) return 'Unsettled balance — settle up first';
    return null;
  }

  bool _selectable(GroupMember member, GroupDetailData data) =>
      widget.canManage && _blockedReason(member, data) == null;

  void _toggle(GroupMember member) {
    setState(() {
      if (!_selected.remove(member.id)) _selected.add(member.id);
    });
  }

  void _endSelecting() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  Future<void> _removeSelected(GroupDetailData data) async {
    final targets = [
      for (final m in data.members)
        if (_selected.contains(m.id)) m,
    ];
    if (targets.isEmpty) return;
    await widget.onRemove(targets);
    if (mounted) _endSelecting();
  }

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    final gutter = context.windowSize.gutter;
    return ListenableBuilder(
      listenable: widget.data,
      builder: (context, _) {
        final data = widget.data.value;
        // The group screen only pushes this once its data has loaded, so the
        // null case is a refresh that failed — the ledger behind still shows
        // the error and the retry.
        if (data == null) return const Scaffold(body: SizedBox.shrink());
        final selectedCount = data.members.where((m) => _selected.contains(m.id)).length;
        return Scaffold(
          appBar: AppBar(
            leading: _selecting
                ? IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed: _endSelecting,
                  )
                : null,
            title: Text(_selecting ? '$selectedCount selected' : 'Members'),
            actions: [
              if (widget.canManage && !_selecting && data.members.length > 1)
                TextButton(
                  onPressed: () => setState(() => _selecting = true),
                  child: const Text('Select'),
                ),
            ],
          ),
          bottomNavigationBar: _selecting && selectedCount > 0
              ? SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 12),
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: slice.negative),
                      onPressed: () => _removeSelected(data),
                      child: Text(
                        selectedCount == 1 ? 'Remove 1 member' : 'Remove $selectedCount members',
                      ),
                    ),
                  ),
                )
              : null,
          body: SafeArea(
            child: PageBody(
              child: ListView(
                padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
                children: [
                  for (final member in data.members)
                    _MemberRow(
                      member: member,
                      me: widget.me,
                      currency: widget.group.currency,
                      net: data.netFor(member.id),
                      isOwner: member.userId == widget.group.ownerId,
                      blocked: _blockedReason(member, data),
                      selecting: _selecting,
                      selected: _selected.contains(member.id),
                      selectable: _selectable(member, data),
                      onTap: () => _selecting && _selectable(member, data)
                          ? _toggle(member)
                          : widget.onOpenMember(member),
                    ),
                  if (data.formerMembers.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text('FORMER MEMBERS', style: sectionLabelStyle(slice.muted)),
                    const SizedBox(height: 6),
                    // Left as a line rather than rows: nothing can be done to
                    // them, and they only need to explain a name that still
                    // shows up in old expenses.
                    Text(
                      data.formerMembers.map((m) => displayName(m, widget.me)).join(', '),
                      style: TextStyle(fontSize: 12.5, color: slice.muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.me,
    required this.currency,
    required this.net,
    required this.isOwner,
    required this.blocked,
    required this.selecting,
    required this.selected,
    required this.selectable,
    required this.onTap,
  });

  final GroupMember member;
  final AppUser me;
  final String currency;
  final int net;
  final bool isOwner;
  final String? blocked;
  final bool selecting;
  final bool selected;
  final bool selectable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    final name = displayName(member, me);
    // Out of selection mode a row says what somebody is; in it, why they
    // can't be picked — the question the user is asking at that moment.
    final role = isOwner ? 'Owner' : 'Member';
    final subtitle = selecting ? (blocked ?? role) : role;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: !selecting || selectable,
      onTap: onTap,
      leading: selecting
          ? Checkbox(value: selected, onChanged: selectable ? (_) => onTap() : null)
          : Avatar(
              initialsFor(member, me),
              imageUrl: member.avatarUrl,
              size: 40,
              background: slice.ink,
              foreground: slice.paper,
            ),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: slice.muted)),
      trailing: MoneyText(net, currency, size: 16),
    );
  }
}
