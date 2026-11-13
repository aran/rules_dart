// Maps a program's recorded uses of `TrimOp` to the native symbols its
// library keeps, one per line.
//
// Usage: symbols <recorded_uses.json> <output>
import 'dart:convert';
import 'dart:io';

import 'package:record_use/record_use.dart';

const _op = Class('TrimOp', Library('package:trim/trim.dart'));

void main(List<String> args) {
  final uses = Recordings.fromJson(
    jsonDecode(File(args[0]).readAsStringSync()) as Map<String, Object?>,
  );
  final symbols = {
    for (final use in uses.instances[_op] ?? const <InstanceReference>[])
      if (use case InstanceConstantReference(
        instanceConstant: InstanceConstant(
          fields: {'name': StringConstant(value: final name)},
        ),
      ))
        'trim_$name',
  };
  File(args[1]).writeAsStringSync([...symbols, ''].join('\n'));
}
