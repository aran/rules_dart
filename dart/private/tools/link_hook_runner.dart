// Runs one package's `hook/link.dart` for a linked program's assets.
//
// Builds the hook's `LinkInput` (package, roots, recorded uses, and the data
// assets the package declares, which its build hook would have routed to it),
// runs the hook on the hermetic SDK's `dart`, checks its `LinkOutput`, and
// copies each data asset it emits to its output: the File Bazel declared for
// each id the package's `link_hook_assets` promise, and the package's output
// directory for the rest. The record it writes names what was emitted, by
// name, and no path, so the same inputs give the same bytes under every
// output layout.
//
// Usage:
//   link_hook_runner --dart <dart> --packages <package_config.json>
//       --package-name <name> --package-root <dir> [--metadata <label>]
//       --recorded-uses <json> --output <record.json> --directory <dir>
//       [--input-data-asset <name>=<path>]...
//       [--promised-data-asset <name>=<path>]...
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
    ..addOption('metadata')
    ..addOption('recorded-uses', mandatory: true)
    ..addOption('output', mandatory: true)
    ..addOption('directory', mandatory: true)
    ..addMultiOption('input-data-asset', splitCommas: false)
    ..addMultiOption('promised-data-asset', splitCommas: false);
  final args = parser.parse(arguments);
  final packageName = args.option('package-name')!;
  final metadata = args.option('metadata');
  final declaration = metadata == null
      ? "the package's `dart_package_metadata`"
      : '`$metadata`';

  // Data assets, by name within the package: those the hook receives, and
  // those it promises to emit.
  Map<String, String> byName(String option) => {
    for (final entry in args.multiOption(option))
      entry.substring(0, entry.indexOf('=')): entry.substring(
        entry.indexOf('=') + 1,
      ),
  };
  final received = byName('input-data-asset');
  final promised = byName('promised-data-asset');
  final directory = Directory(args.option('directory')!);

  final scratch = Directory.systemTemp.createTempSync('dart_link_hook_');
  try {
    final input = _linkInput(
      packageName: packageName,
      packageRoot: Directory(args.option('package-root')!).absolute,
      recordedUses: File(args.option('recorded-uses')!).absolute,
      assets: [
        for (final MapEntry(key: name, value: path) in received.entries)
          DataAsset(
            package: packageName,
            name: name,
            file: File(path).absolute.uri,
          ),
      ],
      scratch: scratch,
    );
    final inputFile = File('${scratch.path}/input.json')
      ..writeAsStringSync(jsonEncode(input.json));

    final hook = await Process.run(File(args.option('dart')!).absolute.path, [
      '--packages=${File(args.option('packages')!).absolute.path}',
      input.packageRoot.resolve('hook/link.dart').toFilePath(),
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

    final emitted = <String, DataAsset>{};
    final errors = [
      ...await ProtocolBase.validateLinkOutput(input, output),
      ...await DataAssetsExtension().validateLinkOutput(input, output),
      for (final asset in output.assets.encodedAssets)
        if (!asset.isDataAsset)
          'emitted a `${asset.type}` asset; a linked program takes only data '
              'assets from a link hook',
      if (output.assets.encodedAssetsForLink.isNotEmpty)
        'routed assets or metadata to the link hooks of '
            '${output.assets.encodedAssetsForLink.keys.join(', ')}. '
            'rules_dart runs each link hook on its own, over its own '
            "package's assets, and passes nothing between link hooks",
    ];
    for (final asset in output.assets.data) {
      if (asset.package != packageName) {
        errors.add(
          'emitted `${asset.id}`, a data asset of another package. A link '
          "hook emits only its own package's data assets, "
          '`package:$packageName/<name>`',
        );
      } else if (emitted.containsKey(asset.name)) {
        errors.add('emitted `${asset.id}` more than once');
      } else if (!_isRelativePath(asset.name)) {
        errors.add(
          'emitted `${asset.id}`, whose name is not a relative path, so its '
          "file would be outside the package's output directory",
        );
      } else {
        emitted[asset.name] = asset;
      }
    }
    final missing = promised.keys.where((n) => !emitted.containsKey(n));
    if (missing.isNotEmpty) {
      errors.add(
        'did not emit ${missing.map((n) => '`package:$packageName/$n`').join(', ')}, '
        'which the `link_hook_assets` of $declaration promise. A hook must '
        'emit every id it promises, whatever the program: remove the id '
        'from `link_hook_assets`, or make the hook always emit it.',
      );
    }
    if (errors.isNotEmpty) {
      _fail(packageName, 'produced unusable output', errors.join('\n'));
    }

    for (final MapEntry(key: name, value: asset) in emitted.entries) {
      final destination = promised[name] ?? '${directory.path}/$name';
      File(destination).parent.createSync(recursive: true);
      File.fromUri(asset.file).copySync(destination);
    }
    // The record names each asset by name only; where its file is follows
    // from the outputs Bazel declared.
    final record = {
      'data': [...emitted.keys]..sort(),
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

bool _isRelativePath(String name) {
  final segments = name.split('/');
  return !name.startsWith('/') &&
      !name.contains(r'\') &&
      segments.every((s) => s.isNotEmpty && s != '.' && s != '..');
}

LinkInput _linkInput({
  required String packageName,
  required Directory packageRoot,
  required File recordedUses,
  required List<DataAsset> assets,
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
      assets: [for (final asset in assets) asset.encode()],
      assetsFromLinking: [],
      recordedUsesFile: recordedUses.uri,
    )
    ..addExtension(DataAssetsExtension());
  return builder.build();
}

Never _fail(String packageName, String what, String detail) =>
    throw _LinkFailure(
      [
        'hook/link.dart of package `$packageName` $what.',
        if (detail.isNotEmpty) detail,
      ].join('\n'),
    );

/// A hook or its output that fails the action; thrown so the scratch
/// directory is still removed.
final class _LinkFailure implements Exception {
  _LinkFailure(this.message);

  final String message;
}
