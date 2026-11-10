/// Runs the program named by `PROGRAM` on this VM and checks what it printed.
///
/// `EXPECT` is the dependency's flavor and greeting, then the entrypoint's: the
/// two must be the same environment.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final program = Runfiles.create().rlocation(Platform.environment['PROGRAM']!);
  final result = Process.runSync(Platform.resolvedExecutable, [program]);
  final out = '${result.stdout}'.trim();
  final expected = Platform.environment['EXPECT']!;
  if (result.exitCode != 0 || out != expected) {
    stderr.writeln(
      'expected "$expected", got exit ${result.exitCode}, stdout "$out", '
      'stderr "${result.stderr}"',
    );
    exit(1);
  }
}
