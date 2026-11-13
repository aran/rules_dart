// Emits the name the package's `lib/` holds.
import 'dart:convert';
import 'dart:io';

import 'package:data_assets/data_assets.dart';
import 'package:ext_hook/ext_hook.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final index = input.outputDirectory.resolve('names.json');
    File.fromUri(index).writeAsStringSync(jsonEncode([name]));
    output.assets.data.add(
      DataAsset(
        package: input.packageName,
        name: 'ext_hook/names.json',
        file: index,
      ),
    );
  });
}
