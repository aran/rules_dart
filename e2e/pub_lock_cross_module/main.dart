import 'dart:io';

import 'package:collection/collection.dart';
import 'package:module_b/greeter.dart';

void main() {
  // Uses module_b's greeter (which internally uses package:path)
  stdout.writeln(greet('world'));

  // Uses collection from root module's pub deps
  final numbers = [3, 1, 4, 1, 5];
  final first = numbers.firstWhereOrNull((n) => n > 4);
  stdout
    ..writeln('First > 4: $first')
    ..writeln('Cross-module test passed!');
}
