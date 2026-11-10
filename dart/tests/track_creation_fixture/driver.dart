// Runs the executable named by `ACTUAL` and fails with its output unless it
// exits 0.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final path = Runfiles.create().rlocation(Platform.environment['ACTUAL']!);
  final result = Process.runSync(path, const []);
  if (result.exitCode != 0) {
    stderr
      ..writeln('$path exited ${result.exitCode}')
      ..write(result.stdout)
      ..write(result.stderr);
    exit(1);
  }
}
