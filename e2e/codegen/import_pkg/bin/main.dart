import 'dart:io';

import 'package:import_fixture/via_package.dart';
import 'package:import_fixture/via_relative.dart';

void main() {
  // `stdout.writeln` rather than `print`: `avoid_print` bans the shorter
  // spelling, and `test/run_test.dart` asserts these exact lines on stdout.
  stdout
    ..writeln('via_package: ${viaPackage()}')
    ..writeln('via_relative: ${viaRelative()}');
}
