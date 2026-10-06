// Writes the index of glyphs the application uses, and fails the build on any
// glyph constructed at run time.
import 'dart:convert';
import 'dart:io';

import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:record_use/record_use.dart';

const _glyph = Class('Glyph', Library('package:glyphs/glyphs.dart'));

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final names = <String>{};
    final uses = input.recordedUses?.instances[_glyph] ?? const [];
    for (final use in uses) {
      switch (use) {
        case InstanceConstantReference(
          instanceConstant: InstanceConstant(
            fields: {'name': StringConstant(value: final name)},
          ),
        ):
          names.add(name);
        case InstanceCreationReference():
          throw BuildError(
            message:
                'glyphs: a Glyph is constructed at run time, so its name '
                'cannot be known when linking. Construct every Glyph with '
                '`const`.',
          );
        case _:
          throw BuildError(message: 'glyphs: unrecognised use $use');
      }
    }
    final index = input.outputDirectory.resolve('index.json');
    File.fromUri(index).writeAsStringSync(jsonEncode(names.toList()..sort()));
    output.assets.data.add(
      DataAsset(
        package: input.packageName,
        name: 'glyphs/index.json',
        file: index,
      ),
    );
  });
}
