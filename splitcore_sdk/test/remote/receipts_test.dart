import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:splitcore_sdk/src/remote/receipts.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

// A flat color lets lossless PNG trivially out-compress any JPEG re-encode
// (degenerate case), a modulo-wrapped pattern is the opposite degenerate
// case (adversarial for JPEG's DCT, ideal for PNG's deflate), and even a
// pure smooth gradient is near-optimal for PNG's row filters (constant
// per-pixel delta). A real photo is a smooth gradient *plus* grain/texture
// — the grain defeats PNG's delta prediction while JPEG's DCT still
// handles it fine at quality 85 — so that's what actually favors JPEG.
Uint8List _syntheticPng(int width, int height) {
  final image = img.Image(width: width, height: height);
  final rnd = Random(42);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      int channel(int base) => (base + rnd.nextInt(31) - 15).clamp(0, 255);
      image.setPixelRgb(
        x,
        y,
        channel(255 * x ~/ width),
        channel(255 * y ~/ height),
        channel(128),
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('compressReceipt (pure, offline)', () {
    test('downscales an oversized image to fit within maxDimension', () {
      final original = _syntheticPng(4000, 2000);

      final compressed = compressReceipt(original, maxDimension: 1600);

      final decoded = img.decodeJpg(compressed)!;
      expect(decoded.width, lessThanOrEqualTo(1600));
      expect(decoded.height, lessThanOrEqualTo(1600));
      expect(compressed.length, lessThan(original.length));
    });

    test('leaves an already-small image at its original dimensions', () {
      final original = _syntheticPng(200, 100);

      final compressed = compressReceipt(original, maxDimension: 1600);

      final decoded = img.decodeJpg(compressed)!;
      expect(decoded.width, 200);
      expect(decoded.height, 100);
    });

    test('output is always JPEG regardless of input format', () {
      final original = _syntheticPng(300, 300);

      final compressed = compressReceipt(original);

      expect(img.decodeJpg(compressed), isNotNull);
    });
  });

  group('attachReceipt (integration, real server)', () {
    late PbTestServer server;
    late PocketBase pb;
    late String splitEntryId;

    setUpAll(() async {
      server = await PbTestServer.start();
      addTearDown(server.stop);

      pb = PocketBase(server.baseUrl);
      final auth = AuthApi(pb);
      final groupsApi = GroupsApi(pb);
      final expensesApi = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));

      await auth.signUp(email: 'payer@example.com', password: 'password123');
      final group = await groupsApi.createGroup(name: 'Trip', currency: 'USD');
      final members = await groupsApi.listMembers(group.id);
      final payer = members.first;

      final expense = await expensesApi.createExpense(
        groupId: group.id,
        payerMemberId: payer.id,
        description: 'Hotel',
        date: DateTime.utc(2026, 7, 1),
        split: SplitSpec.equal(totalCents: 2000, memberIds: [payer.id]),
      );
      final entries = await expensesApi.listSplitEntries(expense.id);
      splitEntryId = entries.single.id;
    });

    test('attaches a compressed receipt to a split entry', () async {
      final jpegBytes = compressReceipt(_syntheticPng(2000, 2000));

      final updated = await attachReceipt(pb, splitEntryId: splitEntryId, jpegBytes: jpegBytes);

      expect(updated.receiptFilename, isNotNull);
      expect(updated.receiptFilename, isNotEmpty);
    });
  });
}
