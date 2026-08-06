// The local source of truth. Opening it runs any outstanding migrations,
// so a caller never sees a half-built schema.
import 'dart:async';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'change_bus.dart';
import 'schema.dart' as sql;

class SplitcoreDb {
  SplitcoreDb._(this.raw) {
    // Off by default in SQLite, and the cascades in schema.dart are load-
    // bearing: deleting an expense has to take its split entries with it.
    raw.execute('PRAGMA foreign_keys = ON');
    migrate();
  }

  /// Opens (or creates) the database file at [path].
  factory SplitcoreDb.openAt(String path) => SplitcoreDb._(sqlite.sqlite3.open(path));

  /// An ephemeral database, for tests. The real engine, no file.
  factory SplitcoreDb.inMemory() => SplitcoreDb._(sqlite.sqlite3.openInMemory());

  /// The schema version this build of the SDK expects.
  static const int schemaVersion = sql.schemaVersion;

  /// The underlying handle. DAOs use this; nothing outside `local/` should.
  final sqlite.Database raw;

  final _bus = ChangeBus();
  bool _inTransaction = false;

  /// The table names touched by each committed transaction.
  Stream<Set<String>> get changes => _bus.changes;

  int get userVersion => raw.select('PRAGMA user_version').first['user_version'] as int;

  /// Applies every migration above the stored version, in order, inside one
  /// transaction — a partly-migrated database is not a state worth
  /// supporting. Idempotent: already-current is a no-op.
  void migrate() {
    final from = userVersion;
    if (from >= schemaVersion) return;

    raw.execute('BEGIN');
    try {
      for (var v = from + 1; v <= schemaVersion; v++) {
        for (final statement in sql.migrations[v]!) {
          raw.execute(statement);
        }
      }
      // PRAGMA takes no bound parameters, and this value is a compile-time
      // constant from schema.dart — never user input.
      raw.execute('PRAGMA user_version = $schemaVersion');
      raw.execute('COMMIT');
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Runs [body] in a transaction and, on commit, announces [tables].
  ///
  /// SQLite has no nested transactions, and the SDK has no case that needs
  /// them: a write is one call. Nesting throws rather than silently
  /// flattening into the outer transaction, where an inner rollback would
  /// discard the outer caller's work without telling them.
  T transaction<T>(Set<String> tables, T Function() body) {
    if (_inTransaction) {
      throw StateError('SplitcoreDb.transaction cannot be nested');
    }
    _inTransaction = true;
    raw.execute('BEGIN');
    try {
      final result = body();
      raw.execute('COMMIT');
      _bus.emit(tables);
      return result;
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    } finally {
      _inTransaction = false;
    }
  }

  /// [query]'s current result, then its result again every time one of
  /// [tables] changes. The immediate first emission is the point: a screen
  /// binding to this renders local data on its first frame, with no loading
  /// state and no network.
  Stream<T> watch<T>(Set<String> tables, T Function() query) {
    late StreamController<T> controller;
    StreamSubscription<Set<String>>? sub;

    void push() {
      if (controller.isClosed) return;
      try {
        controller.add(query());
      } catch (e, s) {
        controller.addError(e, s);
      }
    }

    controller = StreamController<T>(
      onListen: () {
        push();
        sub = _bus.changes.listen((touched) {
          if (touched.any(tables.contains)) push();
        });
      },
      onCancel: () async => sub?.cancel(),
    );
    return controller.stream;
  }

  Future<void> close() async {
    await _bus.close();
    raw.dispose();
  }
}
