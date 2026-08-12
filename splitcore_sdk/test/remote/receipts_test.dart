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
      image.setPixelRgb(x, y, channel(255 * x ~/ width), channel(255 * y ~/ height), channel(128));
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

    test('dropping colour is a real saving', () {
      // A receipt is black print on white paper; the chroma planes carry
      // nothing. (decodeJpg normalises back to three channels on read, so
      // the encoded size is where the difference shows up.)
      final original = _syntheticPng(1200, 1600);

      final grey = compressReceipt(original);
      final colour = compressReceipt(original, grayscale: false);

      expect(grey.length, lessThan(colour.length));
      expect(
        grey.length / colour.length,
        lessThan(0.85),
        reason: 'grayscale should save more than a rounding error',
      );
    });

    // Guards the reason compressReceipt does NOT convert to a single
    // channel, which would be smaller again: package:image's JPEG encoder
    // writes a 1-channel image into one plane and leaves the rest empty,
    // so it decodes as a red-tinted mess (r=130, g=0, b=1) instead of grey.
    // If this ever starts passing, the encoder was fixed and the
    // conversion is worth revisiting.
    test('a compressed receipt decodes as neutral grey', () {
      final decoded = img.decodeJpg(compressReceipt(_syntheticPng(400, 400)))!;

      for (var y = 20; y < 380; y += 37) {
        for (var x = 20; x < 380; x += 37) {
          final p = decoded.getPixel(x, y);
          // JPEG is lossy, so a couple of levels apart is as neutral as a
          // decoded grey gets.
          expect((p.r - p.g).abs(), lessThanOrEqualTo(2), reason: 'r/g differ at $x,$y');
          expect((p.g - p.b).abs(), lessThanOrEqualTo(2), reason: 'g/b differ at $x,$y');
        }
      }
    });

    test('a 12MP photo lands well under 100KB', () {
      // The whole point. A phone photo of a receipt used to upload at a few
      // hundred KB; anything near that means a default has drifted back.
      final compressed = compressReceipt(_syntheticPng(3000, 4000));

      expect(compressed.length, lessThan(100 * 1024));
    });

    test('downsampling averages rather than decimating', () {
      // copyResize defaults to nearest-neighbour, which drops pixels
      // outright: thin strokes alias into broken lines, and the
      // high-frequency mess that creates costs more bytes than smoothing.
      // A 4x downscale of noise should therefore come out *smaller* than
      // the same settings with decimation, and much smoother.
      final original = _syntheticPng(3200, 3200);

      final averaged = compressReceipt(original, maxDimension: 800);
      final decoded = img.decodeJpg(averaged)!;

      // Averaging 16 source pixels into one drives the per-pixel noise of
      // _syntheticPng (±15) down by roughly 4x, so neighbouring pixels end
      // up close together. Decimation would preserve the full swing.
      var totalDelta = 0;
      var samples = 0;
      for (var y = 100; y < 700; y += 7) {
        for (var x = 100; x < 700; x += 7) {
          totalDelta += (decoded.getPixel(x, y).luminance - decoded.getPixel(x + 1, y).luminance)
              .abs()
              .round();
          samples++;
        }
      }
      expect(totalDelta / samples, lessThan(6), reason: 'neighbouring pixels are still noisy');
    });

    test('strips EXIF, so a receipt does not upload its GPS coordinates', () {
      final withGps = img.Image(width: 400, height: 400);
      withGps.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(513, 10);
      withGps.exif.gpsIfd['GPSLongitude'] = img.IfdValueRational(2, 10);
      final original = Uint8List.fromList(img.encodeJpg(withGps));
      expect(img.decodeJpg(original)!.exif.gpsIfd.isEmpty, isFalse, reason: 'fixture has GPS');

      final compressed = compressReceipt(original);

      expect(img.decodeJpg(compressed)!.exif.gpsIfd.isEmpty, isTrue);
    });

    test('bakes EXIF orientation in, so a sideways photo is not stored sideways', () {
      // Phones record rotation in EXIF rather than in the pixels. Dropping
      // the tag without applying it first would leave every camera receipt
      // on its side.
      final landscape = img.Image(width: 400, height: 200);
      // 6 = rotate 90° clockwise: the image is meant to be read portrait.
      landscape.exif.imageIfd['Orientation'] = img.IfdValueShort(6);
      final original = Uint8List.fromList(img.encodeJpg(landscape));

      final decoded = img.decodeJpg(compressReceipt(original))!;

      expect(decoded.width, 200);
      expect(decoded.height, 400);
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
