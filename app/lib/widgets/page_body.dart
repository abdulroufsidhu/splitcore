// Phone-first screens stretch full-width and look broken on tablet/desktop/
// unfolded-foldable. Centering the content column at a readable max width
// fixes that in one place instead of rewriting every screen for wide
// layouts — a no-op on phones, where the constraint is never reached.
//
// The cap grows with the window rather than staying at 560 forever: a
// column sized for a phone, centred in a 1600px pane, reads as an app that
// has not noticed where it is. It still stops well short of the full width,
// because a line of text hundreds of characters long is unreadable no
// matter how much room there is for it.
import 'package:flutter/material.dart';

import '../layout.dart';

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child, this.maxWidth});

  final Widget child;

  /// Overrides the width this page is capped at. Null takes the cap from
  /// the window size class, which is what every caller wants.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final cap =
        maxWidth ??
        switch (context.windowSize) {
          WindowSize.compact => 560.0,
          WindowSize.medium => 640.0,
          WindowSize.expanded => 760.0,
          WindowSize.large => 900.0,
          WindowSize.extraLarge => 1100.0,
        };
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: cap),
        child: child,
      ),
    );
  }
}
