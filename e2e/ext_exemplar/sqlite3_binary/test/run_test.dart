import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Acceptance for the `dart_binary` code_assets path: run the compiled
/// exe (which has the Bazel-built libsqlite3 bound as a code asset) and
/// confirm it resolves sqlite3 at runtime. This is what proves AOT
/// native-asset resolution on each CI platform.
void main() {
  test('sqlite3 dart_binary runs with the Bazel-bundled libsqlite3', () {
    final r = Runfiles.create();
    final exeName = Platform.isWindows ? 'app.exe' : 'app';
    final exe = r.rlocation('_main/sqlite3_binary/$exeName');
    final result = Process.runSync(
      exe,
      [],
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    expect(
      result.exitCode,
      0,
      reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout, contains('sqlite3 ok: hello'));
  });

  test('a `defines` entry survives the code-asset compile pipeline', () {
    final r = Runfiles.create();
    final exeName = Platform.isWindows ? 'app.exe' : 'app';
    final exe = r.rlocation('_main/sqlite3_binary/$exeName');
    final result = Process.runSync(
      exe,
      [],
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    // Regression: `defines` used to be passed to the kernel -> exe stage,
    // where `dart compile` accepts `-D` and ignores it, so this printed
    // `channel: UNSET` with no build-time diagnostic.
    expect(result.stdout, contains('channel: bazel-e2e'));
  });
}
