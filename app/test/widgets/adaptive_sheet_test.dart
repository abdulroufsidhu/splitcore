// The same content, in whichever modal form the window calls for.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/theme.dart';
import 'package:splitcore_app/widgets/adaptive_sheet.dart';

/// Opens a modal from a button, in a window of exactly [size].
Future<String?> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  String? result;
  await tester.pumpWidget(
    MaterialApp(
      theme: sliceLightTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showAdaptiveSheet<String>(
                context: context,
                builder: (sheetContext) => Padding(
                  // The keyboard inset every sheet body carries. In dialog
                  // form it must resolve to zero.
                  padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
                  // Full-width, the way every real sheet body is built, so
                  // whatever it ends up measuring is the modal's own width.
                  child: SizedBox(
                    key: const Key('body'),
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop('picked'),
                      child: const Text('Pick me'),
                    ),
                  ),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('a phone gets a bottom sheet', (tester) async {
    await _open(tester, const Size(393, 852));

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Pick me'), findsOneWidget);
  });

  testWidgets('anything wider gets a dialog', (tester) async {
    await _open(tester, const Size(1280, 900));

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Pick me'), findsOneWidget);
  });

  testWidgets('the dialog is not stretched across the whole window', (tester) async {
    await _open(tester, const Size(3440, 1440));

    // Two text fields spread over 3440px is the thing this exists to stop.
    expect(tester.getSize(find.byKey(const Key('body'))).width, lessThanOrEqualTo(460));
  });

  testWidgets('either form returns what the content popped', (tester) async {
    for (final size in [const Size(393, 852), const Size(1280, 900)]) {
      await _open(tester, size);
      await tester.tap(find.text('Pick me'));
      await tester.pumpAndSettle();
      expect(find.text('Pick me'), findsNothing, reason: 'the modal should have closed at $size');
    }
  });
}
