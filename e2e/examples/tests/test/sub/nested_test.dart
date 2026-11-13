import 'dart:io';

import 'package:utils/math_utils.dart';

void main() {
  if (factorial(5) != 120) {
    stderr.writeln('factorial(5) should be 120');
    exit(1);
  }
  stdout.writeln('Nested test passed!');
}
