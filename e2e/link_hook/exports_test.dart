// Checks which symbols the library a program ships for a code asset exports.
//
// Arguments: the runfiles path of the library, then `+<symbol>` for each
// symbol it must export and `-<symbol>` for each it must not.
import 'dart:ffi';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final library = DynamicLibrary.open(Runfiles.create().rlocation(args.first));
  final wrong = [
    for (final expectation in args.skip(1))
      if (library.providesSymbol(expectation.substring(1)) !=
          expectation.startsWith('+'))
        expectation,
  ];
  if (wrong.isNotEmpty) {
    stdout.writeln('FAIL: ${args.first} does not meet $wrong');
    exit(1);
  }
}
