import 'dart:convert';
import 'dart:io';

import 'args.dart';
import 'compile.dart';
import 'directives.dart';
import 'manifest.dart';
import 'uris.dart';

/// `entry`: a test's main file to a kernel file, with `frontend_server`.
///
/// The main file's imports name libraries; the modules holding them, and the
/// modules those need, are all the program can run. One of them that is
/// unsupported or failed is a program that cannot be built, and this is where
/// it is said so. The others are handed to the compiler and recorded in
/// `--selection-output` for `link`.
Future<int> runEntry(Args args) async {
  final label = args.one('label');
  final output = args.one('output');
  final roots = args.all('multi-root');
  final configPath = args.one('package-config');
  final configRelative = rootRelative(configPath, roots);
  final config = PackageConfig.parse(
    File(configPath).readAsStringSync(),
    configRelative,
  );
  final manifests = args.depManifests();
  final index = ModuleIndex(manifests);

  final main = args.one('main');
  final mainUri = config.uriFor(rootRelative(main, roots));
  final imported = <String>[];
  for (final d in readDirectives(
    main,
    File(main).readAsStringSync(),
  ).directives) {
    final import = resolveImport(d, mainUri, null, config);
    for (final uri in import.reached) {
      if (uri.startsWith('dart:')) continue;
      if (index.moduleOf(uri) == null) {
        // Of an undecidable import's branches only some need exist.
        if (import.selected != null) {
          stderr.writeln(
            '$label: $main imports $uri, which no dependency compiles. Add '
            'the target that holds it to deps.',
          );
          return 1;
        }
        continue;
      }
      imported.add(uri);
    }
  }

  final reach = index.reach(imported);
  if (reachError(label, main, reach) case final error?) {
    stderr.writeln(error);
    return 1;
  }

  var sdkRoot = args.one('sdk-root').replaceAll(r'\', '/');
  if (!sdkRoot.endsWith('/')) sdkRoot = '$sdkRoot/';

  // Separate `--import-dill` files do not work: in either order the server
  // fails to resolve an export from one module of a library in another. One
  // file of all the modules does.
  final platform = args.one('platform').replaceAll(r'\', '/');
  final temp = Directory.systemTemp.createTempSync('kernel_tool_');
  final imports = '${temp.path}/modules.dill';
  final CompileResult result;
  try {
    await concatenate([for (final m in reach.order) m.dillPath!], imports);
    result = await runProcess(args.one('runtime'), [
      args.one('snapshot'),
      '--sdk-root',
      sdkRoot,
      // Read relative to `--sdk-root`.
      '--platform',
      platform.startsWith(sdkRoot)
          ? platform.substring(sdkRoot.length)
          : platform,
      '--target',
      args.optional('target') ?? 'vm',
      for (final d in args.all('define')) '-D$d',
      if (args.flag('track-creation-locations')) '--track-creation-locations',
      '--filesystem-scheme',
      rootScheme,
      for (final root in roots) ...['--filesystem-root', root],
      '--packages',
      rootUri(configRelative),
      if (reach.order.isNotEmpty) ...['--import-dill', imports],
      '--no-link-platform',
      '--output-dill',
      output,
      if (args.optional('native-assets') case final assets?) ...[
        '--native-assets',
        assets,
      ],
      mainUri,
    ]);
  } finally {
    temp.deleteSync(recursive: true);
  }
  final server = FrontendServerOutput.parse(result.output);
  if (result.exitCode != 0 || server.errorCount != 0) {
    // The server writes the kernel even when it reports errors.
    deleteIfPresent(output);
    stderr.write(server.diagnostics);
    if (server.errorCount == null && result.exitCode == 0) {
      stderr.writeln('$label: frontend_server did not report a result');
    }
    return 1;
  }

  File(args.one('unused-inputs-output')).writeAsStringSync(
    [for (final dir in unusedModuleDirs(manifests, reach)) '$dir\n'].join(),
  );
  File(args.one('selection-output')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'modules': [
        for (final m in reach.order)
          {'label': m.manifest.label, 'id': m.module.id},
      ],
    }),
  );
  return 0;
}

/// The module directories of [manifests] that [reach] has nothing in: Bazel
/// does not rerun the compile when only these change. A directory is one
/// input to Bazel, so one whose modules are reached in part stays an input.
List<String> unusedModuleDirs(List<Manifest> manifests, ModuleReach reach) {
  final reached = {for (final m in reach.order) m.manifest};
  return [
    for (final manifest in manifests)
      if (!reached.contains(manifest)) manifest.dir,
  ];
}

/// The message for a program that reaches a module that is unsupported or
/// failed, naming the first such module the walk met; null when it reaches
/// none.
String? reachError(String label, String main, ModuleReach reach) {
  final unusable = reach.discovered.where((m) => !m.module.isOk).firstOrNull;
  if (unusable == null) return null;
  return '$label: $main reaches ${reach.via[unusable]} '
      '(${unusable.manifest.label}), which '
      '${unusable.module.reason ?? 'cannot be used'}';
}
