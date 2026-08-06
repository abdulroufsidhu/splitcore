// PocketBase record ids are 15 characters of [a-z0-9], and PocketBase
// accepts a client-supplied `id` on create. Minting ids here is what makes
// offline writes possible at all: a split entry can reference an expense
// the server has never seen, and replaying a create that already landed
// fails with `validation_not_unique`, which reads as "already applied" —
// so retries are idempotent for free.
import 'dart:math';

const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

// Random.secure() rather than Random(): ids are identifiers that appear in
// URLs and filter expressions, and a predictable sequence would let one
// user guess another's record ids.
final _random = Random.secure();

String newLocalId() => String.fromCharCodes([
  for (var i = 0; i < 15; i++) _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
]);
