import 'dart:io';

import 'package:part_pkg_fixture/message.dart';

void main() {
  // `stdout.writeln` rather than `print`: `avoid_print` bans the shorter
  // spelling, and `test/run_test.dart` asserts this exact line on stdout.
  stdout.writeln('message: ${message()}');
}
