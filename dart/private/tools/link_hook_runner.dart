// Runs one package's `hook/link.dart` for a linked program's assets.
//
// Builds the hook's `LinkInput` (package, roots, recorded uses, and the data
// and code assets the package declares, which its build hook would have
// routed to it), runs the hook on the hermetic SDK's `dart`, checks its
// `LinkOutput`, and copies each data asset it emits to its output: the File
// Bazel declared for each id the package's `link_hook_assets` promise, and the
// package's output directory, at its name, for the rest. A code asset it emits
// must be one it received, as it was declared: the same id, link mode and
// file. `--code-selection` gets the ids of those it keeps, one per line, and
// no path, so the same inputs give the same bytes under every output layout.
//
// Usage:
//   link_hook_runner --dart <dart> --packages <package_config.json>
//       --package-name <name> --package-root <dir> [--metadata <label>]
//       --recorded-uses <json> --directory <dir>
//       [--input-data-asset <name>=<path>]...
//       [--promised-data-asset <name>=<path>]...
//       [--code-config <json> [--input-code-asset <id>=<link mode>=<path or uri>]...
//        --code-selection <file>]
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:code_assets/code_assets.dart';
import 'package:data_assets/data_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('dart', mandatory: true)
    ..addOption('packages', mandatory: true)
    ..addOption('package-name', mandatory: true)
    ..addOption('package-root', mandatory: true)
    ..addOption('metadata')
    ..addOption('recorded-uses', mandatory: true)
    ..addOption('directory', mandatory: true)
    ..addOption('code-selection')
    ..addMultiOption('input-data-asset', splitCommas: false)
    ..addMultiOption('promised-data-asset', splitCommas: false)
    ..addOption('code-config')
    ..addMultiOption('input-code-asset', splitCommas: false);
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
  final codeConfig = switch (args.option('code-config')) {
    final json? => jsonDecode(json) as Map<String, Object?>,
    null => null,
  };
  final receivedCode = [
    for (final entry in args.multiOption('input-code-asset'))
      _codeAsset(entry.split('=')),
  ];

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
          ).encode(),
        for (final asset in receivedCode) asset.encode(),
      ],
      codeConfig: codeConfig,
      scratch: scratch,
    );
    final code = codeConfig == null ? null : _codeExtension(input);
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
      ...?await code?.validateLinkOutput(input, output),
      for (final asset in output.assets.encodedAssets)
        if (!asset.isDataAsset && !(code != null && asset.isCodeAsset))
          'emitted a `${asset.type}` asset; a linked program takes only data '
              'and code assets from a link hook',
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
    // A code asset it keeps is one it received, as it was declared: the
    // program's kernel maps ids before any hook runs, so one kept under
    // another id would not load.
    final kept = <String>{};
    final receivedById = {for (final r in receivedCode) r.id: r};
    String path(Uri file) => File.fromUri(file).absolute.path;
    for (final asset
        in code == null ? const <CodeAsset>[] : output.assets.code) {
      final declared = receivedById[asset.id];
      final sameFile = receivedCode
          .where(
            (r) =>
                asset.file != null &&
                r.file != null &&
                path(r.file!) == path(asset.file!),
          )
          .firstOrNull;
      if (!asset.id.startsWith('package:$packageName/')) {
        errors.add(
          'emitted code asset `${asset.id}`, an id of another package. A '
          "link hook emits its own package's code assets, "
          '`package:$packageName/<name>`',
        );
      } else if (kept.contains(asset.id)) {
        errors.add('emitted code asset `${asset.id}` more than once');
      } else if (declared == null && sameFile != null) {
        errors.add(
          'emitted code asset `${sameFile.id}` as `${asset.id}`. A link hook '
          'keeps a code asset under the id its package declares: the '
          "program's kernel maps ids before linking, so it would not load "
          'under another',
        );
      } else if (declared == null) {
        errors.add(
          'emitted code asset `${asset.id}`, whose '
          '${asset.file == null ? 'link mode' : 'file ${asset.file!.toFilePath()}'} '
          'is none of the code assets its package declares'
          '${receivedCode.isEmpty ? '' : ' (${receivedCode.map((r) => '`${r.id}`').join(', ')})'}. '
          'A link hook selects among those, and builds no native code: '
          'native code linked for each program is a `dart_linked_code_asset` '
          'in the `linked_code_assets` of $declaration',
        );
      } else if (declared.linkMode != asset.linkMode) {
        errors.add(
          'emitted code asset `${asset.id}` with link mode '
          '`${_linkModeName(asset.linkMode)}`, but its package declares it '
          'with `${_linkModeName(declared.linkMode)}`. A link hook keeps a '
          'code asset as its package declares it',
        );
      } else if ((asset.file == null) != (declared.file == null) ||
          (asset.file != null && path(asset.file!) != path(declared.file!))) {
        errors.add(
          'emitted code asset `${asset.id}` with '
          '${asset.file == null ? 'no file' : 'file ${asset.file!.toFilePath()}'}, '
          'which is not the file its package declares for it. A link hook '
          'selects among its package\'s code assets, and builds no native '
          'code: native code linked for each program is a '
          '`dart_linked_code_asset` in the `linked_code_assets` of $declaration',
        );
      } else {
        kept.add(asset.id);
      }
    }
    errors.addAll(_nameCollisions(packageName, [...emitted.keys]));
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
    directory.createSync(recursive: true);
    if (args.option('code-selection') case final selection?) {
      File(selection).writeAsStringSync(
        [
          for (final id in [...kept]..sort()) '$id\n',
        ].join(),
      );
    }
  } on _LinkFailure catch (failure) {
    stderr.writeln(failure.message);
    exitCode = 1;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// What makes two emitted names unusable together: names that differ only in
/// case are one file on a case-insensitive file system, and a name that is a
/// directory of another cannot also be a file. Either way, a consumer listing
/// the package's output directory would see something other than what the
/// hook emitted.
List<String> _nameCollisions(String packageName, List<String> names) {
  final errors = <String>[];
  String id(String name) => '`package:$packageName/$name`';
  final byFolded = <String, String>{};
  for (final name in [...names]..sort()) {
    final other = byFolded[name.toLowerCase()];
    if (other != null) {
      errors.add(
        'emitted ${id(other)} and ${id(name)}, whose names differ only in '
        'case: on a case-insensitive file system they are one file',
      );
    } else {
      byFolded[name.toLowerCase()] = name;
    }
  }
  final all = names.toSet();
  for (final name in [...names]..sort()) {
    final segments = name.split('/');
    for (var i = 1; i < segments.length; i++) {
      final prefix = segments.take(i).join('/');
      if (all.contains(prefix)) {
        errors.add(
          'emitted ${id(prefix)} and ${id(name)}: a name cannot be both a '
          'file and a directory of another',
        );
      }
    }
  }
  return errors;
}

String _linkModeName(LinkMode mode) => mode.toJson()['type']! as String;

bool _isRelativePath(String name) {
  final segments = name.split('/');
  return !name.startsWith('/') &&
      !name.contains(r'\') &&
      segments.every((s) => s.isNotEmpty && s != '.' && s != '..');
}

/// A code asset given as `<id>=<link mode>=<path or uri>`.
CodeAsset _codeAsset(List<String> parts) {
  final [id, mode, location] = parts;
  final package = id.substring('package:'.length, id.indexOf('/'));
  return CodeAsset(
    package: package,
    name: id.substring(id.indexOf('/') + 1),
    linkMode: LinkMode.fromJson({
      'type': mode,
      if (mode == 'dynamic_loading_system') 'uri': location,
    }),
    file: mode == 'dynamic_loading_bundle' ? File(location).absolute.uri : null,
  );
}

/// The code-asset protocol extension the input was set up with, to check the
/// hook's output against. What it warns of (a library it cannot read the
/// architecture of) goes to stderr.
CodeAssetExtension _codeExtension(LinkInput input) {
  final code = input.config.code;
  final logger = Logger.detached('code_assets')
    ..level = Level.WARNING
    ..onRecord.listen((record) => stderr.writeln(record.message));
  return CodeAssetExtension(
    targetArchitecture: code.targetArchitecture,
    targetOS: code.targetOS,
    linkModePreference: code.linkModePreference,
    android: code.targetOS == OS.android ? code.android : null,
    iOS: code.targetOS == OS.iOS ? code.iOS : null,
  )..setupLogger(logger);
}

LinkInput _linkInput({
  required String packageName,
  required Directory packageRoot,
  required File recordedUses,
  required List<EncodedAsset> assets,
  required Map<String, Object?>? codeConfig,
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
      assets: assets,
      assetsFromLinking: [],
      recordedUsesFile: recordedUses.uri,
    )
    ..addExtension(DataAssetsExtension());
  if (codeConfig != null) {
    // Upstream's configuration of the target, as given: the program step
    // states it in upstream's own terms.
    builder.config.addBuildAssetTypes(['code_assets/code']);
    final config = builder.json['config']! as Map<String, Object?>;
    (config['extensions'] ??= <String, Object?>{}) as Map<String, Object?>;
    (config['extensions']! as Map<String, Object?>)['code_assets'] = codeConfig;
  }
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
