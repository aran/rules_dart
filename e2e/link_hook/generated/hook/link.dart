// Emits the names a generator wrote into the package's generated part.
import 'dart:convert';
import 'dart:io';

import 'package:data_assets/data_assets.dart';
import 'package:generated_hook/parts.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final index = input.outputDirectory.resolve('names.json');
    File.fromUri(index).writeAsStringSync(jsonEncode(names));
    output.assets.data.add(
      DataAsset(
        package: input.packageName,
        name: 'generated_hook/names.json',
        file: index,
      ),
    );
  });
}
