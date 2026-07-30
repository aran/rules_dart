import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// A plain `package:sqlite3` program — no `dart:ffi` ceremony. The BUILD's
/// `code_assets = [sqlite3_code_asset()]` embeds the Bazel-built libsqlite3
/// into the compiled binary as a code asset, so `sqlite3`'s `@Native`
/// bindings resolve against it at runtime (relative to the executable).
void main() {
  final db = sqlite3.openInMemory();
  db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT);');
  db.execute("INSERT INTO t (id, name) VALUES (1, 'hello');");
  final rows = db.select('SELECT name FROM t WHERE id = ?;', [1]);
  final name = rows.single['name'] as String;
  db.dispose();
  if (name != 'hello') {
    stderr.writeln('FAIL: expected "hello", got "$name"');
    exit(1);
  }
  stdout.writeln(
    'sqlite3 ok: $name (libVersion ${sqlite3.version.libVersion})',
  );

  // `const` forces resolution during constant evaluation, which is the stage
  // the code-asset pipeline runs in gen_kernel rather than in `dart compile`.
  stdout.writeln(
    'channel: ${const String.fromEnvironment('BUILD_CHANNEL', defaultValue: 'UNSET')}',
  );
}
