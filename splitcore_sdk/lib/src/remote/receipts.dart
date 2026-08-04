// Receipt pipeline: downscale + JPEG re-encode client-side before upload
// (the server never resizes images), then attach to a split_entries row.
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

/// Downscales [bytes] (any format `image` can decode) so neither dimension
/// exceeds [maxDimension], then re-encodes as JPEG at [quality]. Images
/// already within bounds are re-encoded but not resized.
Uint8List compressReceipt(Uint8List bytes, {int maxDimension = 1600, int quality = 85}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw ArgumentError.value(bytes, 'bytes', 'not a decodable image');
  }

  var image = decoded;
  if (image.width > maxDimension || image.height > maxDimension) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxDimension)
        : img.copyResize(image, height: maxDimension);
  }

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
