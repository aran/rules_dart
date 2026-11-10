// The package Gazelle split over one BUILD file per directory of `lib/`
// resolves as one package.
import 'dart:io';

import 'package:split/a.dart';
import 'package:split/src/model/model.dart';

void main() {
  final failures = [
    if (describe(' a ') != 'MODEL A') 'describe: ${describe(' a ')}',
    if ('${Model('b')}' != 'model b') 'Model: ${Model('b')}',
  ];
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
}
