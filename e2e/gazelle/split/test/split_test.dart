// A package with files in directories under `lib/` is one library, at the
// package's root.
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
