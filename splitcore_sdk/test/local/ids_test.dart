import 'package:splitcore_sdk/src/local/ids.dart';
import 'package:test/test.dart';

void main() {
  test("an id matches PocketBase's own format: 15 chars of [a-z0-9]", () {
    for (var i = 0; i < 1000; i++) {
      expect(newLocalId(), matches(RegExp(r'^[a-z0-9]{15}$')));
    }
  });

  test('ids do not collide', () {
    final ids = {for (var i = 0; i < 10000; i++) newLocalId()};
    expect(ids, hasLength(10000));
  });
}
