// A bottom sheet on a phone, a dialog everywhere else.
//
// A sheet sliding up from the bottom edge of a 1440p window is the most
// obviously phone-shaped thing an app can do: the content lands hundreds of
// pixels from where the user was looking, and it stretches the full width
// of the monitor to hold two text fields. Above `compact` the same content
// is centred in a dialog instead.
import 'package:flutter/material.dart';

import '../layout.dart';

/// Shows [builder]'s content as a modal, in whichever form suits the window.
///
/// Call sites are unchanged from `showModalBottomSheet` apart from the
/// name — including their `MediaQuery.viewInsets.bottom` padding, which
/// exists to lift a sheet above the keyboard. In dialog form that padding
/// resolves to zero, because the insets are stripped from the subtree: a
/// dialog is already centred clear of the keyboard, and adding the
/// keyboard's height underneath it would push its buttons off screen.
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  double maxDialogWidth = 460,
  bool scrollable = true,
}) {
  if (context.isCompact) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      builder: builder,
    );
  }

  return showDialog<T>(
    context: context,
    builder: (dialogContext) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxDialogWidth),
        child: MediaQuery.removeViewInsets(
          context: dialogContext,
          removeBottom: true,
          // Sheet bodies are built as `mainAxisSize: min` columns, which a
          // dialog honours — but a long one still has to be able to scroll
          // rather than overflow the window. `scrollable: false` is for
          // the bodies that size and scroll themselves; wrapping one of
          // those hands it an unbounded height and its Expanded throws.
          child: scrollable
              ? SingleChildScrollView(child: builder(dialogContext))
              : builder(dialogContext),
        ),
      ),
    ),
  );
}
