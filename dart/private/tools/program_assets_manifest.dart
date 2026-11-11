// Writes a linked program's asset manifest.
//
// The plan, written at analysis time, holds the assets known then (those of
// packages without a link hook) and, for each package with one, where its
// hook's record and outputs are and the code assets it received. Each record
// names what the hook emitted: data assets by name, code assets by the input
// each keeps. This resolves each to its file and writes every asset, sorted
// by id, as `DartProgramAssetsInfo.manifest` describes.
//
// Usage:
//   program_assets_manifest --plan <plan.json> --output <manifest.json>
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

void main(List<String> arguments) {
  final args =
      (ArgParser()
            ..addOption('plan', mandatory: true)
            ..addOption('output', mandatory: true))
          .parse(arguments);
  final plan = jsonDecode(
    File(args.option('plan')!).readAsStringSync(),
  ) as Map<String, Object?>;
  final assets = [
    for (final asset in plan['assets']! as List<Object?>)
      asset! as Map<String, Object?>,
  ];
  final packages = plan['packages']! as Map<String, Object?>;
  for (final MapEntry(key: package, value: entry) in packages.entries) {
    final hook = entry! as Map<String, Object?>;
    final promised = hook['promised']! as Map<String, Object?>;
    final record = jsonDecode(
      File(hook['record']! as String).readAsStringSync(),
    ) as Map<String, Object?>;
    // A kept code asset is the input it names, under the id it was given.
    final codeInputs = hook['code_inputs']! as Map<String, Object?>;
    for (final kept
        in (record['code']! as List<Object?>).cast<Map<String, Object?>>()) {
      assets.add({
        'encoding': {
          ...codeInputs[kept['input']]! as Map<String, Object?>,
          'id': kept['id'],
        },
        'type': 'code_assets/code',
      });
    }
    for (final name in (record['data']! as List<Object?>).cast<String>()) {
      // Keys in order, as the entries written at analysis time have them.
      assets.add({
        'encoding': {
          'file': promised[name] ?? '${hook['directory']}/$name',
          'name': name,
          'package': package,
        },
        'type': 'data_assets/data',
      });
    }
  }
  assets.sort((a, b) => _id(a).compareTo(_id(b)));
  File(args.option('output')!).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({'assets': assets}),
  );
}

String _id(Map<String, Object?> asset) {
  final encoding = asset['encoding']! as Map<String, Object?>;
  return encoding['id'] as String? ??
      'package:${encoding['package']}/${encoding['name']}';
}
