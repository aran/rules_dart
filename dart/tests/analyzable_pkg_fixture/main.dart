/// The entrypoint: outside `lib/`, so no `package:` URI reaches it, and it
/// reaches its own package's sources only through the record the constructor
/// puts in the nested `DartInfo`.
library;

import 'dart:io';

import 'package:analyzable_pkg/model.dart';
import 'package:analyzable_pkg/view.dart';

void main() {
  stdout.writeln(describe(const Model('fixture')));
}
