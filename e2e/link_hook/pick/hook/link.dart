// Keeps the native libraries of the operations the program uses, out of the
// ones the build hook routed here, as they are. An `Op('built')` instead emits
// a library of its own, an `Op('renamed')` keeps `add` under another id, and
// an `Op('relinked')` keeps `add` with another link mode, which a link hook
// may not.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:record_use/record_use.dart';

const _op = Class('Op', Library('package:pick/pick.dart'));

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final used = {
      for (final use in input.recordedUses?.instances[_op] ?? const [])
        if (use case InstanceConstantReference(
          instanceConstant: InstanceConstant(
            fields: {'name': StringConstant(value: final name)},
          ),
        ))
          name,
    };
    for (final asset in input.assets.code) {
      final name = asset.id.substring('package:pick/'.length);
      if (used.contains(name)) {
        output.assets.code.add(asset);
      }
      if (name == 'add' && used.contains('renamed')) {
        output.assets.code.add(asset.copyWith(id: 'package:pick/renamed'));
      }
      if (name == 'add' && used.contains('relinked')) {
        output.assets.code.add(
          CodeAsset(package: 'pick', name: 'add', linkMode: LookupInProcess()),
        );
      }
    }
    if (used.contains('built')) {
      final library = File.fromUri(input.outputDirectory.resolve('built.so'))
        ..writeAsStringSync('');
      output.assets.code.add(
        CodeAsset(
          package: 'pick',
          name: 'built',
          linkMode: DynamicLoadingBundled(),
          file: library.uri,
        ),
      );
    }
  });
}
