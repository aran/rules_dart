// An executable's entrypoint in the 3.6 package: short style, like lib/.
import 'dart:io';

import 'package:short/short.dart';

void main() {
  stdout.writeln(describeMeasurement(
      'the first argument', 'the second argument', describe()));
}
