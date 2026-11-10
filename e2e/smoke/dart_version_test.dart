import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// The `dart` launcher of the toolchain's SDK runs and reports its version.
///
/// The first argument is the launcher's runfiles path (`$(rlocationpath ...)`).
void main(List<String> args) {
  final dart = Runfiles.create().rlocation(args.first);
  final result = Process.runSync(dart, ['--version']);
  final output = '${result.stdout}${result.stderr}';
  print('dart --version output: $output');

  if (!output.contains('Dart SDK version')) {
    print("FAIL: expected 'Dart SDK version' in output");
    exit(1);
  }
  print('PASS: dart binary is runnable and reports version');
}
