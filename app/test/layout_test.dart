// The width → size-class mapping, both sides of every boundary.
//
// Every layout decision in the app hangs off these five numbers, so an
// off-by-one here shows up as a rail appearing on a phone rather than as a
// failing assertion somewhere obvious.
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/layout.dart';

void main() {
  test('width maps to the expected size class on both sides of each boundary', () {
    // Real devices, not just the boundaries: a folded cover screen, a
    // phone, a tablet, a laptop and an ultrawide.
    expect(WindowSize.fromWidth(320), WindowSize.compact);
    expect(WindowSize.fromWidth(393), WindowSize.compact);
    expect(WindowSize.fromWidth(599.9), WindowSize.compact);

    expect(WindowSize.fromWidth(600), WindowSize.medium);
    expect(WindowSize.fromWidth(839.9), WindowSize.medium);

    expect(WindowSize.fromWidth(840), WindowSize.expanded);
    expect(WindowSize.fromWidth(1199.9), WindowSize.expanded);

    expect(WindowSize.fromWidth(1200), WindowSize.large);
    expect(WindowSize.fromWidth(1599.9), WindowSize.large);

    expect(WindowSize.fromWidth(1600), WindowSize.extraLarge);
    expect(WindowSize.fromWidth(3440), WindowSize.extraLarge);
  });

  test('a phone gets no rail, no panes', () {
    const phone = WindowSize.compact;
    expect(phone.isCompact, isTrue);
    expect(phone.hasRail, isFalse);
    expect(phone.hasDetailPane, isFalse);
    expect(phone.hasInspectorPane, isFalse);
  });

  test('the rail arrives before the second pane does', () {
    // A tablet in portrait has room to navigate but not to show two
    // things at once; getting this backwards gives a cramped split view.
    expect(WindowSize.medium.hasRail, isTrue);
    expect(WindowSize.medium.hasDetailPane, isFalse);
    expect(WindowSize.expanded.hasDetailPane, isTrue);
  });

  test('only an ultrawide gets the inspector', () {
    expect(WindowSize.large.hasInspectorPane, isFalse);
    expect(WindowSize.extraLarge.hasInspectorPane, isTrue);
  });

  test('gutters and titles grow with the window, never shrink', () {
    var previousGutter = 0.0;
    var previousTitle = 0.0;
    for (final size in WindowSize.values) {
      expect(size.gutter, greaterThanOrEqualTo(previousGutter), reason: '$size gutter');
      expect(size.titleSize, greaterThanOrEqualTo(previousTitle), reason: '$size title');
      previousGutter = size.gutter;
      previousTitle = size.titleSize;
    }
  });

  testWidgets('context.windowSize reads the window width, and ignores its height', (tester) async {
    late WindowSize portrait;
    late WindowSize landscape;

    Widget host(Size size, void Function(WindowSize) sink) => MediaQuery(
      data: MediaQueryData(size: size),
      child: Builder(
        builder: (context) {
          sink(context.windowSize);
          return const SizedBox();
        },
      ),
    );

    await tester.pumpWidget(host(const Size(400, 900), (s) => portrait = s));
    // Turned sideways, the same 400x900 phone is 900 wide and does get the
    // two-pane layout. That is the intent: the classes measure horizontal
    // room, which is the only thing panes and rails need.
    await tester.pumpWidget(host(const Size(900, 400), (s) => landscape = s));

    expect(portrait, WindowSize.compact);
    expect(landscape, WindowSize.expanded);
  });

  testWidgets('a vertical hinge reports its centre', (tester) async {
    double? center;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(1600, 900),
          displayFeatures: [
            DisplayFeature(
              // Tall and narrow: a fold running down the middle.
              bounds: Rect.fromLTRB(792, 0, 808, 900),
              type: DisplayFeatureType.hinge,
              state: DisplayFeatureState.postureFlat,
            ),
          ],
        ),
        child: Builder(
          builder: (context) {
            center = verticalHingeCenter(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(center, 800);
  });

  testWidgets('a horizontal fold is not a vertical hinge', (tester) async {
    double? center;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: const Size(900, 1600),
          displayFeatures: [
            // Wide and short: a flip phone's crease. Splitting panes on it
            // would put the list above the detail, which is not what a
            // side-by-side layout is for.
            DisplayFeature(
              bounds: Rect.fromLTRB(0, 792, 900, 808),
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureHalfOpened,
            ),
          ],
        ),
        child: Builder(
          builder: (context) {
            center = verticalHingeCenter(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(center, isNull);
  });
}
