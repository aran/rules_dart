import 'dart:io';

import 'package:greeter/greeter.dart';

import 'version.dart';

void main() {
  stdout
    ..writeln('library_deps v$version')
    ..writeln(greet('world'))
    ..writeln(greet('dart'));
}
