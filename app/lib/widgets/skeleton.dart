// Plain static placeholder blocks shown during first load, instead of a
// bare spinner. No shimmer/animation package — just rounded boxes over
// the theme's card/chip color, which reads as "content is coming" rather
// than "app froze".
import 'package:flutter/material.dart';

import '../theme.dart';

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height = 14, this.radius = 6});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: context.slice.chip, borderRadius: BorderRadius.circular(radius)),
    );
  }
}

/// A handful of list-row-shaped skeleton blocks, for screens whose real
/// content is a `ListView` of similarly-shaped rows (group list, activity
/// feed, group detail).
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 6});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      itemCount: count,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const SkeletonBox(width: 44, height: 44, radius: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 140),
                  const SizedBox(height: 8),
                  const SkeletonBox(width: 90, height: 11),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
