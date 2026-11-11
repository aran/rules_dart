// Checks the assets a program ships, as a consumer that opened every file its
// manifest names reported them (`read_assets`).
//
// Arguments: the runfiles path of that report, then one argument per asset:
// `<id>=<content>` for a data asset, whose file must have held that content,
// and `<id>` for a code asset, whose file must have been there. The manifest
// must list exactly those.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final report = File(Runfiles.create().rlocation(args.first))
      .readAsLinesSync()
      .where((line) => line.isNotEmpty);
  final shipped = {
    for (final line in report)
      // Without quotes: an argument cannot carry them.
      line.substring(0, line.indexOf('=')): line
          .substring(line.indexOf('=') + 1)
          .replaceAll('"', ''),
  };
  final expected = {
    for (final pair in args.skip(1).map((a) => a.split('=')))
      pair.first: pair.length > 1 ? pair.last : '',
  };
  final ok =
      shipped.length == expected.length &&
      expected.entries.every((e) => shipped[e.key] == e.value);
  if (!ok) {
    stdout.writeln('FAIL: shipped $shipped, expected $expected');
    exit(1);
  }
}
