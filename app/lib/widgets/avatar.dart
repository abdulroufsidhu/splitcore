// Initial-circle avatar used for members, group icons and the header
// account button across every screen in the design.
import 'package:flutter/material.dart';

import '../theme.dart';

class Avatar extends StatelessWidget {
  const Avatar(
    this.label, {
    super.key,
    this.size = 36,
    this.background,
    this.foreground,
    this.imageUrl,
    this.semanticLabel,
  });

  final String label;
  final double size;

  /// Defaults to the theme's chip/muted colors (light or dark) when null.
  final Color? background;
  final Color? foreground;

  /// When non-empty, shows this image instead of the initials — falling
  /// back to initials on load failure (e.g. offline).
  final String? imageUrl;

  /// What a screen reader should announce. Null means "decorative": the
  /// raw initials ("MS") are duplication of a name that is almost always
  /// rendered next to the avatar, so announcing them is noise.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final avatar = _build(context);
    return semanticLabel == null
        ? ExcludeSemantics(child: avatar)
        : Semantics(
            label: semanticLabel,
            image: true,
            child: ExcludeSemantics(child: avatar),
          );
  }

  Widget _build(BuildContext context) {
    final slice = context.slice;
    final initials = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background ?? slice.chip, shape: BoxShape.circle),
      child: Text(
        label,
        style: TextStyle(
          color: foreground ?? slice.muted,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.38,
        ),
      ),
    );
    if (imageUrl == null || imageUrl!.isEmpty) return initials;
    return ClipOval(
      child: Image.network(
        imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => initials,
        loadingBuilder: (context, child, progress) => progress == null ? child : initials,
      ),
    );
  }
}
