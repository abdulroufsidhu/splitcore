// The local source of truth. Opening it runs any outstanding migrations,
// so a caller never sees a half-built schema.
import 'package:sqlite3/sqlite3.dart' as sqlite;

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

  void close() => raw.dispose();
}
