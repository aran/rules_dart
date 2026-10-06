// Runs one package's `hook/link.dart` for `dart_link_hook`.
//
// Builds the hook's `LinkInput` (package, roots, recorded uses), runs the hook
// on the hermetic SDK's `dart`, checks its `LinkOutput`, and copies each data
// asset it emits to the output Bazel declared for that asset's id.
//
// Usage:
//   link_hook_runner --dart <dart> --packages <package_config.json>
//       --package-name <name> --package-root <dir> --hook <hook/link.dart>
//       --recorded-uses <json> --output <link_output.json>
//       [--data-asset <name>=<path>]...
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('dart', mandatory: true)
    ..addOption('packages', mandatory: true)
    ..addOption('package-name', mandatory: true)
    ..addOption('package-root', mandatory: true)
    ..addOption('hook', mandatory: true)
    ..addOption('recorded-uses', mandatory: true)
    ..addOption('output', mandatory: true)
    ..addMultiOption('data-asset', splitCommas: false);
  final args = parser.parse(arguments);
  final packageName = args.option('package-name')!;

  // Declared data assets, by name within the package.
  final declared = <String, String>{};
  for (final entry in args.multiOption('data-asset')) {
    final at = entry.indexOf('=');
    declared[entry.substring(0, at)] = entry.substring(at + 1);
  }

  final scratch = Directory.systemTemp.createTempSync('dart_link_hook_');
  try {
    final input = _linkInput(
      packageName: packageName,
      packageRoot: Directory(args.option('package-root')!).absolute,
      recordedUses: File(args.option('recorded-uses')!).absolute,
      scratch: scratch,
    );
    final inputFile = File('${scratch.path}/input.json')
      ..writeAsStringSync(jsonEncode(input.json));

    final hook = await Process.run(File(args.option('dart')!).absolute.path, [
      '--packages=${File(args.option('packages')!).absolute.path}',
      File(args.option('hook')!).absolute.path,
      '--config=${inputFile.path}',
    ], workingDirectory: input.packageRoot.toFilePath());
    final hookLog = [
      if ('${hook.stderr}'.trim().isNotEmpty) '${hook.stderr}'.trim(),
      if ('${hook.stdout}'.trim().isNotEmpty) '${hook.stdout}'.trim(),
    ].join('\n');
    final outputFile = File.fromUri(input.outputFile);
    if (hook.exitCode != 0) {
      _fail(packageName, 'exited with code ${hook.exitCode}', hookLog);
    }
    if (!outputFile.existsSync()) {
      _fail(packageName, 'wrote no output', hookLog);
    }
    final outputJson =
        jsonDecode(outputFile.readAsStringSync()) as Map<String, Object?>;
    final output = switch (LinkOutputMaybeFailure(outputJson)) {
      final LinkOutput success => success,
      final LinkOutputFailure failure => _fail(
        packageName,
        'reported a ${failure.type.name} failure',
        hookLog,
      ),
    };

    final errors = [
      ...await ProtocolBase.validateLinkOutput(input, output),
      ...await DataAssetsExtension().validateLinkOutput(input, output),
      for (final asset in output.assets.encodedAssets)
        if (!asset.isDataAsset)
          'emitted a `${asset.type}` asset; dart_link_hook collects only '
              'data assets',
      if (output.assets.encodedAssetsForLink.isNotEmpty)
        'routed assets to the link hooks of '
            '${output.assets.encodedAssetsForLink.keys.join(', ')}; '
            'dart_link_hook runs each hook on its own',
    ];
    if (errors.isNotEmpty) {
      _fail(packageName, 'produced unusable output', errors.join('\n'));
    }

    final emitted = {for (final asset in output.assets.data) asset.name: asset};
    final undeclared = emitted.keys.where((n) => !declared.containsKey(n));
    final missing = declared.keys.where((n) => !emitted.containsKey(n));
    if (undeclared.isNotEmpty || missing.isNotEmpty) {
      String ids(Iterable<String> names) =>
          names.map((n) => '  package:$packageName/$n').join('\n');
      _fail(
        packageName,
        'emitted data assets other than the ones `data_assets` declares',
        [
          if (undeclared.isNotEmpty)
            'Emitted but not declared:\n${ids(undeclared)}',
          if (missing.isNotEmpty) 'Declared but not emitted:\n${ids(missing)}',
        ].join('\n'),
      );
    }
    for (final MapEntry(key: name, value: path) in declared.entries) {
      File.fromUri(emitted[name]!.file).copySync(path);
    }
    // The record kept of the hook's output names each asset by its declared
    // output rather than the scratch file it was copied from, and drops the
    // timestamp, so the same inputs always produce the same bytes.
    final record = {
      'assets': [
        for (final name in declared.keys)
          DataAsset(
            package: packageName,
            name: name,
            file: Uri.file(declared[name]!),
          ).encode().toJson(),
      ],
    };
    File(args.option('output')!)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(record));
  } on _LinkFailure catch (failure) {
    stderr.writeln(failure.message);
    exitCode = 1;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

LinkInput _linkInput({
  required String packageName,
  required Directory packageRoot,
  required File recordedUses,
  required Directory scratch,
}) {
  final builder = LinkInputBuilder()
    ..setupShared(
      packageRoot: packageRoot.uri,
      packageName: packageName,
      outputDirectoryShared: Directory('${scratch.path}/shared').uri,
      outputFile: File('${scratch.path}/output.json').uri,
    )
    ..setupLink(
      assets: [],
      assetsFromLinking: [],
      recordedUsesFile: recordedUses.uri,
    )
    ..addExtension(DataAssetsExtension());
  return builder.build();
}

Never _fail(String packageName, String what, String detail) =>
    throw _LinkFailure(
      [
        'dart_link_hook: hook/link.dart of package `$packageName` $what.',
        if (detail.isNotEmpty) detail,
      ].join('\n'),
    );

/// A hook or its output that fails the action; thrown so the scratch
/// directory is still removed.
final class _LinkFailure implements Exception {
  _LinkFailure(this.message);

  final String message;
}
