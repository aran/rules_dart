import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:value/value.dart';

/// The SDK in use is the minimum, and a program it compiled ahead of time runs.
void main() {
  if (!Platform.version.startsWith('3.13.0 ')) {
    stderr.writeln('This test runs on Dart ${Platform.version}');
    exit(1);
  }
  final program = Runfiles.create().rlocation(Platform.environment['PROGRAM']!);
  final result = Process.runSync(program, const []);
  if ('${result.stdout}'.trim() != value()) {
    stderr.writeln('The program said: ${result.stdout}${result.stderr}');
    exit(1);
  }
}
