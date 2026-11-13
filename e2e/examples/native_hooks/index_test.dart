// Checks each link hook's index against the glyphs its input used.
//
// Arguments: pairs of an index's runfiles path and the comma-separated glyph
// names it must list, in order, or `(none)` for an empty index.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  var failed = false;
  for (var i = 0; i < args.length; i += 2) {
    final index = File(runfiles.rlocation(args[i]));
    final actual = (jsonDecode(index.readAsStringSync()) as List).join(',');
    final expected = args[i + 1] == '(none)' ? '' : args[i + 1];
    if (actual != expected) {
      stdout.writeln('FAIL: ${args[i]} lists "$actual", expected "$expected"');
      failed = true;
    }
  }
  if (failed) exit(1);
}
