// Imports a file of the package that no target declares.
import 'dart:io';

import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:undeclared_hook/extra.dart';

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final file = input.outputDirectory.resolve('$extra.json');
    File.fromUri(file).writeAsStringSync('[]');
    output.assets.data.add(
      DataAsset(
        package: input.packageName,
        name: 'undeclared_hook/$extra.json',
        file: file,
      ),
    );
  });
}
