// The package's library, holding its import cycles, builds and runs, and so
// does a test helper in a directory of its own.
import 'dart:io';

import 'package:cycle/cycle.dart';

import 'support/check.dart';

void main() {
  final failures = [
    ...problems(greet('you')),
    if ('${countdown(2)}' != '[2, 1, 0]') 'countdown: ${countdown(2)}',
  ];
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
}
