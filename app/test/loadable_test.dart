import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/loadable.dart';

void main() {
  test('starts idle, then holds the loaded value', () async {
    final loadable = Loadable<int>(() async => 42);

    expect(loadable.value, isNull);
    expect(loadable.isLoading, isFalse);

    await loadable.load();

    expect(loadable.value, 42);
    expect(loadable.error, isNull);
    expect(loadable.isLoading, isFalse);
  });

  test('captures a failure instead of throwing', () async {
    final loadable = Loadable<int>(() async => throw StateError('boom'));

    await loadable.load();

    expect(loadable.error, isA<StateError>());
    expect(loadable.value, isNull);
  });

  test('retry clears the previous error and can succeed', () async {
    var attempt = 0;
    final loadable = Loadable<int>(() async {
      attempt++;
      if (attempt == 1) throw StateError('first attempt fails');
      return attempt;
    });

    await loadable.load();
    expect(loadable.error, isNotNull);

    await loadable.retry();

    expect(loadable.error, isNull);
    expect(loadable.value, 2);
  });

  test('a reload keeps the old value visible while loading', () async {
    final gate = Completer<int>();
    var call = 0;
    final loadable = Loadable<int>(() {
      call++;
      return call == 1 ? Future.value(1) : gate.future;
    });

    await loadable.load();
    final reload = loadable.load();

    // Mid-reload: still showing the previous value, and marked loading.
    expect(loadable.value, 1, reason: 'reload blanked the screen');
    expect(loadable.isLoading, isTrue);
    expect(loadable.isInitialLoad, isFalse);

    gate.complete(2);
    await reload;
    expect(loadable.value, 2);
  });

  test('isInitialLoad is true only while there is nothing to show', () async {
    final gate = Completer<int>();
    final loadable = Loadable<int>(() => gate.future);

    final pending = loadable.load();
    expect(loadable.isInitialLoad, isTrue);

    gate.complete(7);
    await pending;
    expect(loadable.isInitialLoad, isFalse);
  });

  test('a failed reload keeps the last good value on screen', () async {
    var call = 0;
    final loadable = Loadable<int>(() async {
      call++;
      if (call == 1) return 1;
      throw StateError('refresh failed');
    });

    await loadable.load();
    await loadable.load();

    // The user was looking at data; a failed refresh must not replace it
    // with an error screen.
    expect(loadable.value, 1);
    expect(loadable.error, isNotNull);
  });

  test('setValue replaces the value without a round trip', () async {
    var calls = 0;
    final loadable = Loadable<int>(() async {
      calls++;
      return 1;
    });
    await loadable.load();

    loadable.setValue(99);

    expect(loadable.value, 99);
    expect(loadable.error, isNull);
    expect(calls, 1, reason: 'setValue must not re-run the loader');
  });

  test('notifies listeners on every state change', () async {
    final loadable = Loadable<int>(() async => 1);
    var notifications = 0;
    loadable.addListener(() => notifications++);

    await loadable.load();

    expect(notifications, greaterThanOrEqualTo(2), reason: 'loading start and finish');
  });
}
