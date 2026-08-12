// How wide the window is, and what that means.
//
// One definition of the breakpoints, so "is this a phone?" is answered the
// same way in every screen instead of each one inventing its own number.
// The classes are Material 3's window size classes; the extra meaning the
// app attaches to them (rail, panes, inspector) lives here too, next to the
// widths that trigger it.
import 'package:flutter/material.dart';

/// Material 3 window size classes, by window *width*.
///
/// Height is deliberately not part of this. Every layout decision the app
/// makes — rail, panes, inspector — is about horizontal room, and folding
/// height in would make a phone in landscape claim to be a tablet.
enum WindowSize {
  /// Phone portrait, a folded foldable's cover screen, a split-screen
  /// phone. The app's floor, and its baseline: nothing below 600 changes
  /// from what shipped before this existed.
  compact,

  /// Tablet portrait, a small unfolded foldable. Wide enough for a rail,
  /// not for two panes of content.
  medium,

  /// Tablet landscape, a small desktop window. Two panes.
  expanded,

  /// A normal desktop window. Two panes, more generous.
  large,

  /// An ultrawide monitor, or a trifold opened flat. Three panes.
  extraLarge;

  static WindowSize fromWidth(double width) {
    if (width >= 1600) return WindowSize.extraLarge;
    if (width >= 1200) return WindowSize.large;
    if (width >= 840) return WindowSize.expanded;
    if (width >= 600) return WindowSize.medium;
    return WindowSize.compact;
  }

  bool operator >=(WindowSize other) => index >= other.index;
  bool operator >(WindowSize other) => index > other.index;
  bool operator <=(WindowSize other) => index <= other.index;
  bool operator <(WindowSize other) => index < other.index;

  /// Push navigation, bottom sheets, full-screen forms — the phone app.
  bool get isCompact => this == WindowSize.compact;

  /// A navigation rail replaces the home screen's top icon row.
  bool get hasRail => this >= WindowSize.medium;

  /// The group list and one group sit side by side, instead of the list
  /// pushing a route on top of itself.
  bool get hasDetailPane => this >= WindowSize.expanded;

  /// Balances and members get a column of their own, instead of a
  /// horizontal strip above the expense list.
  bool get hasInspectorPane => this == WindowSize.extraLarge;

  /// The page margin. A 20px gutter reads as generous on a phone and as
  /// cramped at 1600px.
  double get gutter => switch (this) {
    WindowSize.compact => 16,
    WindowSize.medium => 20,
    WindowSize.expanded => 24,
    WindowSize.large || WindowSize.extraLarge => 32,
  };

  /// Fixed pane widths. The detail pane takes whatever is left, so it is
  /// the one that grows with the window.
  double get listPaneWidth => this >= WindowSize.large ? 380 : 340;
  double get inspectorPaneWidth => 320;

  /// Page titles ("SlicePay", a group's name).
  double get titleSize => switch (this) {
    WindowSize.compact => 26,
    WindowSize.medium || WindowSize.expanded => 28,
    WindowSize.large || WindowSize.extraLarge => 32,
  };
}

extension WindowSizeContext on BuildContext {
  /// The current window size class.
  ///
  /// Reads `MediaQuery.sizeOf` rather than `MediaQuery.of` so that a
  /// keyboard opening — which changes `viewInsets`, not `size` — does not
  /// rebuild every layout in the tree.
  WindowSize get windowSize => WindowSize.fromWidth(MediaQuery.sizeOf(this).width);

  /// Shorthand for the most-asked question.
  bool get isCompact => windowSize.isCompact;

  /// The page margin for this window. See [WindowSize.gutter].
  double get gutter => windowSize.gutter;
}

/// Where a vertical hinge crosses the window, in logical pixels from the
/// left, or null when there isn't one.
///
/// A pane boundary placed anywhere else on a foldable puts half a list
/// across a physical crease. Returns the *centre* of the hinge so a pane
/// split can sit on it; callers that need the hinge's thickness read
/// `displayFeatures` themselves.
double? verticalHingeCenter(BuildContext context) {
  for (final feature in MediaQuery.of(context).displayFeatures) {
    final isVertical = feature.bounds.width < feature.bounds.height;
    if (isVertical && feature.bounds.height > 0) {
      return feature.bounds.left + feature.bounds.width / 2;
    }
  }
  return null;
}
