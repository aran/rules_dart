// Prints what a program ships, as `ProgramAssets.describe` writes it.
//
// Usage: list --program-assets=<file>, or list <file>: a file in the
// program-assets line format, as `program_assets_action_args()` gives an
// action's tool one.
import 'dart:io';

import 'package:program_assets/program_assets.dart';

void main(List<String> args) {
  const flag = '--program-assets=';
  if (args.length != 1) {
    stderr.writeln('Usage: list --program-assets=<file> | list <file>');
    exit(2);
  }
  final path = args.single.startsWith(flag)
      ? args.single.substring(flag.length)
      : args.single;
  try {
    stdout.write(ProgramAssets.read(path).describe());
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}
