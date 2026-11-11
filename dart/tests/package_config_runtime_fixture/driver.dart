// Runs each executable named in `PROGRAMS` and fails with its output unless
// it exits 0.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  for (final program in Platform.environment['PROGRAMS']!.split(' ')) {
    final path = runfiles.rlocation(program);
    final result = Process.runSync(path, const []);
    if (result.exitCode != 0) {
      stderr
        ..writeln('$path exited ${result.exitCode}')
        ..write(result.stdout)
        ..write(result.stderr);
      exit(1);
    }
  }
}
