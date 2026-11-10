// Checks the data assets a program ships.
//
// Arguments: the runfiles paths of the assets, separated by spaces, then the
// `<name>=<content>` each must hold, one argument each, matched by basename.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final shipped = {
    for (final path in args.first.split(' '))
      path.split('/').last: File(runfiles.rlocation(path)).readAsStringSync(),
  };
  final expected = {
    for (final pair in args.skip(1).map((a) => a.split('=')))
      pair.first: '${pair.last}\n',
  };
  final ok =
      shipped.length == expected.length &&
      expected.entries.every((e) => shipped[e.key] == e.value);
  if (!ok) {
    stdout.writeln('FAIL: shipped $shipped, expected $expected');
    exit(1);
  }
}
