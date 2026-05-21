import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The `dart_binary` consumer: run the compiled exe (which imports two
/// Bazel-generated standalone libraries — one via `package:`, one relative).
void main() {
  test('dart_binary runs with Bazel-generated imported libraries', () {
    final r = Runfiles.create();
    final exeName = Platform.isWindows ? 'app.exe' : 'app';
    final exe = r.rlocation('_main/import_pkg/$exeName');
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
    expect(result.stdout, contains('via_package: generated lib works'));
    expect(result.stdout, contains('via_relative: generated lib works'));
  });
}
