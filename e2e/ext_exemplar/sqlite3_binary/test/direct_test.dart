import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Exercises the `dart_test` code_assets path directly, with no codegen: a
/// plain `package:sqlite3` program whose `@Native` bindings resolve against
/// the Bazel-built libsqlite3 (bound via `code_assets`). This complements
/// `app_run_test` (the `dart_binary`/AOT path) and isolates code-asset `.so`
/// resolution — which happens at *test* time via the runtime gen_kernel,
/// using an absolute `rlocation` path — from any codegen co-location concern.
void main() {
  test('sqlite3 round-trips via the Bazel-bundled libsqlite3', () {
    final db = sqlite3.openInMemory()
      ..execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);')
      ..execute("INSERT INTO t (id, name) VALUES (1, 'hello');");
    final rows = db.select('SELECT name FROM t WHERE id = ?;', [1]);
    expect(rows.single['name'], 'hello');
    // The BCR-vendored version — proves we resolved *our* Bazel-built lib,
    // not a system libsqlite3 that happens to be present on the host.
    expect(sqlite3.version.libVersion, '3.53.3');
    db.close();
  });
}
