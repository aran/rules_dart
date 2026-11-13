// Reads what programs ship from a test's runfiles, as any test or program
// with a `dart_program_assets` in its `data` can.
//
// Arguments: for each program, the runfiles path of its target's
// `<name>.program_assets`, then one argument per asset: `<id>=<content>` for a
// data asset, whose file must hold that content, and `<id>` for a code asset,
// whose file must be there; programs separated by `;`. Each must ship exactly
// those.
import 'dart:io';

import 'package:program_assets/program_assets.dart';
import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final failures = <String>[];
  var program = <String>[];
  void check() {
    final [listing, ...expected] = program;
    final assets = ProgramAssets.read(
      runfiles.rlocation(listing),
      runfiles: runfiles,
    );
    final shipped = {
      for (final asset in assets.data)
        asset.id: File(asset.file)
            .readAsStringSync()
            .trim()
            .replaceAll('"', ''),
      for (final asset in assets.code)
        if (File(asset.file!).existsSync()) asset.id: '',
    };
    final wanted = {
      for (final pair in expected.map((a) => a.split('=')))
        pair.first: pair.length > 1 ? pair.last : '',
    };
    if (shipped.length != wanted.length ||
        wanted.entries.any((e) => shipped[e.key] != e.value)) {
      failures.add('$listing: shipped $shipped, expected $wanted');
    }
  }

  for (final arg in args) {
    if (arg == ';') {
      check();
      program = [];
    } else {
      program.add(arg);
    }
  }
  check();
  if (failures.isNotEmpty) {
    stdout.writeln('FAIL:\n${failures.join('\n')}');
    exit(1);
  }
}
