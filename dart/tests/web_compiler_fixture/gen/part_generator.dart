/// Stands in for a real generator: writes each `--output` as a part of the
/// library that declares it, `model.dart`. The tests here assert at analysis
/// time; the outputs exist so that a library collecting them builds, its
/// import check included.
library;

import 'dart:io';

void main(List<String> args) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--output') {
      File(args[i + 1]).writeAsStringSync("part of 'model.dart';\n");
    }
  }
}
