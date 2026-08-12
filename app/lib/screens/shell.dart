// What the window is actually laid out as, at every width.
//
// On a phone this is a pass-through: the home screen is the app, and
// tapping a group pushes it, exactly as before. Everything below is what
// happens once there is room for more than one thing at a time.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import '../display_name.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'account.dart';
import 'activity.dart';
import 'group_detail.dart';
import 'home.dart';

/// The rail's destinations. Account is one of them rather than an avatar
/// tucked in a corner: with a rail there is room to say what it is.
enum _Destination { groups, activity, account }

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.sdk,
    required this.me,
    required this.onSignedOut,
    required this.onProfileUpdated,
    this.homeLoadOverride,
  });

  /// Null only in widget tests, which supply [homeLoadOverride] instead.
  final SplitcoreSdk? sdk;
  final AppUser me;
  final VoidCallback onSignedOut;
  final ValueChanged<AppUser> onProfileUpdated;

  /// Test seam, forwarded to [HomeScreen.loadOverride] — the shell has no
  /// data of its own worth faking.
  @visibleForTesting
  final Future<List<GroupRow>> Function()? homeLoadOverride;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  _Destination _destination = _Destination.groups;

  /// The group showing in the detail pane. Only ever set on layouts that
  /// have one — on a phone, opening a group pushes a route instead.
  Group? _selected;

  /// Kept only because the account screen's export needs the list. Watched
  /// rather than fetched once so a group created or deleted in the pane
  /// does not leave a stale export list behind it.
  List<Group> _groups = const [];
  StreamSubscription<List<Group>>? _groupsSub;

  @override
  void initState() {
    super.initState();
    _groupsSub = widget.sdk?.groups.watchGroups().listen((groups) {
      if (!mounted) return;
      setState(() {
        _groups = groups;
        // A group can vanish underneath the pane: deleted here, or deleted
        // by its owner on another device and dropped by the next pull.
        if (_selected != null && !groups.any((g) => g.id == _selected!.id)) {
          _selected = null;
        }
      });
    });
  }

  @override
  void dispose() {
    unawaited(_groupsSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = context.windowSize;

    // A phone is the app as it was: one screen, push navigation, no rail.
    if (!size.hasRail) return _home(showChrome: true);

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _Rail(
              me: widget.me,
              destination: _destination,
              onSelected: (d) => setState(() => _destination = d),
            ),
            Expanded(child: _content(size)),
          ],
        ),
      ),
    );
  }

  Widget _content(WindowSize size) => switch (_destination) {
    _Destination.activity => ActivityScreen(sdk: widget.sdk, me: widget.me),
    _Destination.account => AccountScreen(
      sdk: widget.sdk,
      me: widget.me,
      groups: _groups,
      onSignedOut: widget.onSignedOut,
    ),
    _Destination.groups => size.hasDetailPane ? _listAndDetail(size) : _home(showChrome: false),
  };

  Widget _listAndDetail(WindowSize size) {
    final slice = context.slice;
    // A pane boundary anywhere but the hinge puts half a list across a
    // physical crease. When there is one, the list pane ends on it.
    final hinge = verticalHingeCenter(context);
    final railWidth = _Rail.width;
    final listWidth = hinge != null && hinge > railWidth + 200 && hinge < railWidth + 700
        ? hinge - railWidth
        : size.listPaneWidth;

    return Row(
      children: [
        SizedBox(width: listWidth, child: _home(showChrome: false)),
        VerticalDivider(width: 1, thickness: 1, color: slice.border),
        Expanded(
          child: _selected == null
              ? _EmptyPane(label: 'Select a group')
              // Keyed by group so switching groups gives the pane a fresh
              // navigator rather than leaving the previous group's Add
              // expense route sitting on the new group's stack.
              : _DetailPane(
                  key: ValueKey(_selected!.id),
                  sdk: widget.sdk,
                  me: widget.me,
                  group: _selected!,
                ),
        ),
      ],
    );
  }

  Widget _home({required bool showChrome}) => HomeScreen(
    sdk: widget.sdk,
    me: widget.me,
    onSignedOut: widget.onSignedOut,
    onProfileUpdated: widget.onProfileUpdated,
    showChrome: showChrome,
    loadOverride: widget.homeLoadOverride,
    // Null on layouts without a detail pane, which is what makes the home
    // screen push a route instead of reporting a selection.
    onGroupSelected: context.windowSize.hasDetailPane
        ? (group) => setState(() => _selected = group)
        : null,
    selectedGroupId: _selected?.id,
  );
}

/// The detail pane's own [Navigator].
///
/// This is what lets `add_expense`, `settle_up` and the rest keep their
/// existing `Navigator.of(context).push` calls: those pushes land inside
/// the pane instead of covering the window, and back works, because a
/// Navigator is already the thing that does this. Dialogs and modal sheets
/// are unaffected — both default to `useRootNavigator: true`, so they
/// still centre over the whole window.
class _DetailPane extends StatelessWidget {
  const _DetailPane({super.key, required this.sdk, required this.me, required this.group});

  final SplitcoreSdk? sdk;
  final AppUser me;
  final Group group;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (settings) => MaterialPageRoute(
        settings: settings,
        builder: (_) => GroupDetailScreen(sdk: sdk, me: me, group: group),
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(label, style: TextStyle(color: context.slice.muted)),
  );
}

class _Rail extends StatelessWidget {
  const _Rail({required this.me, required this.destination, required this.onSelected});

  /// Flutter's NavigationRail has no width getter, and the hinge-snapping
  /// arithmetic needs one. This is the default rail width.
  static const double width = 80;

  final AppUser me;
  final _Destination destination;
  final ValueChanged<_Destination> onSelected;

  @override
  Widget build(BuildContext context) {
    final slice = context.slice;
    return NavigationRail(
      backgroundColor: slice.paper,
      selectedIndex: destination.index,
      onDestinationSelected: (i) => onSelected(_Destination.values[i]),
      labelType: NavigationRailLabelType.all,
      leading: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Icon(Icons.pie_chart_outline, color: slice.ink),
      ),
      destinations: [
        const NavigationRailDestination(
          icon: Icon(Icons.groups_outlined),
          selectedIcon: Icon(Icons.groups),
          label: Text('Groups'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.receipt_long_outlined),
          selectedIcon: Icon(Icons.receipt_long),
          label: Text('Activity'),
        ),
        NavigationRailDestination(
          icon: Avatar(
            meInitial(me),
            imageUrl: me.avatarUrl,
            size: 24,
            background: slice.chip,
            foreground: slice.ink,
          ),
          label: const Text('Account'),
        ),
      ],
    );
  }
}
