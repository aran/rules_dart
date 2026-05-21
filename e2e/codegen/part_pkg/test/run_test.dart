import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The `dart_binary` consumer: run the compiled exe (whose library uses a
/// Bazel-generated `part`) and confirm it produces the part-defined output.
void main() {
  test('dart_binary runs with a Bazel-generated part file', () {
    final r = Runfiles.create();
    final exeName = Platform.isWindows ? 'app.exe' : 'app';
    final exe = r.rlocation('_main/part_pkg/$exeName');
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
    expect(result.stdout, contains('message: generated part works'));
  });
}
