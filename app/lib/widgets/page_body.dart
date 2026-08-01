// Phone-first screens stretch full-width and look broken on tablet/desktop/
// unfolded-foldable. Centering the content column at a readable max width
// fixes that in one place instead of rewriting every screen for wide
// layouts — a no-op on phones, where the constraint is never reached.
import 'package:flutter/material.dart';

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child, this.maxWidth = 560});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
