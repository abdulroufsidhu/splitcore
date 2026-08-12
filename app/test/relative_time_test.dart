import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/relative_time.dart';

void main() {
  final now = DateTime.utc(2026, 8, 5, 12, 0);

  test('describes how stale the data is, in coarse units', () {
    expect(formatRelative(now.subtract(const Duration(seconds: 5)), now: now), 'just now');
    expect(formatRelative(now.subtract(const Duration(minutes: 1)), now: now), '1 minute ago');
    expect(formatRelative(now.subtract(const Duration(minutes: 42)), now: now), '42 minutes ago');
    expect(formatRelative(now.subtract(const Duration(hours: 1)), now: now), '1 hour ago');
    expect(formatRelative(now.subtract(const Duration(hours: 5)), now: now), '5 hours ago');
    expect(formatRelative(now.subtract(const Duration(days: 1)), now: now), '1 day ago');
    expect(formatRelative(now.subtract(const Duration(days: 9)), now: now), '9 days ago');
  });

  test('singular and plural do not cross over at the boundaries', () {
    expect(formatRelative(now.subtract(const Duration(seconds: 59)), now: now), 'just now');
    expect(formatRelative(now.subtract(const Duration(seconds: 60)), now: now), '1 minute ago');
    expect(formatRelative(now.subtract(const Duration(minutes: 59)), now: now), '59 minutes ago');
    expect(formatRelative(now.subtract(const Duration(minutes: 60)), now: now), '1 hour ago');
    expect(formatRelative(now.subtract(const Duration(hours: 23)), now: now), '23 hours ago');
    expect(formatRelative(now.subtract(const Duration(hours: 24)), now: now), '1 day ago');
  });
}
