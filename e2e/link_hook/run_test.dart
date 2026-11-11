// Runs a binary and checks what it prints.
//
// Arguments: the binary's runfiles path, then the line it must print.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final result = Process.runSync(Runfiles.create().rlocation(args[0]), []);
  if (result.exitCode != 0 || '${result.stdout}'.trim() != args[1]) {
    stdout.writeln(
      'FAIL: exit ${result.exitCode}, printed "${result.stdout}" '
      '${result.stderr}, expected "${args[1]}"',
    );
    exit(1);
  }
}
