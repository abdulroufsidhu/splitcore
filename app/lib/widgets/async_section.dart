// Renders a Loadable as the three things a user can be looking at:
// a skeleton, a failure they can act on, or the content.
//
// The error state is deliberately a real recovery affordance, not a red
// string: a failed load with no retry button forces the user to back out
// of the screen and come in again to try the same request.
import 'package:flutter/material.dart';

import '../loadable.dart';
import '../theme.dart';

class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    super.key,
    required this.loadable,
    required this.builder,
    required this.skeleton,
    this.errorLabel,
  });

  final Loadable<T> loadable;
  final Widget Function(BuildContext context, T value) builder;
  final Widget skeleton;

  /// What failed, in the user's terms — "Couldn't load your groups".
  /// Falls back to a generic line when omitted.
  final String? errorLabel;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: loadable,
      builder: (context, _) {
        // Content wins over a later error: once the user has data on
        // screen, a failed refresh must not swap it for an error page.
        final value = loadable.value;
        if (value != null) return builder(context, value);
        if (loadable.error != null) {
          return _ErrorState(
            label: errorLabel ?? 'Something went wrong.',
            error: loadable.error!,
            onRetry: loadable.retry,
          );
        }
        return skeleton;
      },
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.label, required this.error, required this.onRetry});

  final String label;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.slice;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: colors.muted),
            const SizedBox(height: 12),
            Text(label, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            // The raw error is second-class: useful when someone reports a
            // problem, never the headline.
            Text(
              '$error',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.muted),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
