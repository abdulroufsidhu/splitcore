// Receipt pipeline: downscale + JPEG re-encode client-side before upload
// (the server never resizes images), then attach to a split_entries row.
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

/// Downscales [bytes] (any format `image` can decode) so neither dimension
/// exceeds [maxDimension], then re-encodes as a single-channel JPEG at
/// [quality]. Images already within bounds are re-encoded but not resized.
///
/// The defaults are tuned for what a receipt actually is — small black
/// print on white thermal paper, photographed by a phone — rather than for
/// a photograph:
///
///   * **Resolution is the legibility budget.** Text dies from too few
///     pixels per character long before it dies from JPEG quality, so the
///     long edge is kept generous and the savings are taken elsewhere.
///   * **Grayscale.** A receipt carries no colour information, and flat
///     chroma planes cost almost nothing to encode. (Converting to a
///     genuinely single-channel image would be smaller still, but
///     `package:image`'s JPEG encoder mishandles it — the output decodes
///     as `r=130, g=0, b=1`, a red-tinted mess rather than a monochrome
///     image. Three channels it is.)
///   * **Area-averaged downsampling.** `copyResize` defaults to
///     nearest-neighbour, which decimates a 4000px photo by discarding
///     pixels: strokes alias into broken lines, and the high-frequency mess
///     that creates costs *more* bytes than smoothing does. Averaging is
///     both more readable and smaller.
///
/// Together those take a 12MP receipt photo from roughly 280KB to 60KB.
Uint8List compressReceipt(
  Uint8List bytes, {
  int maxDimension = 1400,
  int quality = 65,
  bool grayscale = true,
}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw ArgumentError.value(bytes, 'bytes', 'not a decodable image');
  }

  // A phone camera records rotation in EXIF rather than in the pixels, and
  // the tag is dropped below. Baking it in first is what keeps a receipt
  // upright instead of sideways.
  var image = img.bakeOrientation(decoded);

  if (image.width > maxDimension || image.height > maxDimension) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxDimension, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: maxDimension, interpolation: img.Interpolation.average);
  }

  if (grayscale) image = img.grayscale(image);

  // Everything the camera attached goes: the orientation is baked in above,
  // and the rest is bytes nobody asked to upload — including, on most
  // phones, the GPS coordinates of wherever the receipt was photographed.
  image.exif = img.ExifData();

  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

/// Uploads [jpegBytes] as the `receipt` file on the given split_entries
/// record and returns the updated SplitEntry.
Future<SplitEntry> attachReceipt(
  PocketBase pb, {
  required String splitEntryId,
  required Uint8List jpegBytes,
  String filename = 'receipt.jpg',
}) async {
  final record = await pb
      .collection('split_entries')
      .update(
        splitEntryId,
        files: [http.MultipartFile.fromBytes('receipt', jpegBytes, filename: filename)],
      );
  return SplitEntry(
    id: record.id,
    expenseId: record.getStringValue('expense'),
    memberId: record.getStringValue('member'),
    amountCents: record.getIntValue('amount_cents'),
    receiptFilename: record.getStringValue('receipt').isEmpty
        ? null
        : record.getStringValue('receipt'),
  );
}
