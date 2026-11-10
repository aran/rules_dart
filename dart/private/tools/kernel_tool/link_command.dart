import 'dart:convert';
import 'dart:io';

import 'args.dart';
import 'compile.dart';
import 'manifest.dart';

/// `link`: the program the entry and the modules it selected make, as one file
/// the VM can run. A library two selected modules both define is refused: the
/// front end silently used one copy, and which depended on the order.
///
/// With `--list-short-path`, the program is a kernel list rather than a joined
/// kernel: `#@dill`, then one line per kernel, the entry first, each the path
/// from the list to that kernel in the runfiles tree. `--list-short-path` is
/// the list's own `short_path`, `--entry-short-path` the entry's, and each
/// `--dep-short-path` that of the module directory of the `--dep-manifest` in
/// the same place; `--workspace-name` places the main repository's in
/// runfiles. Only the manifests and the selection are read then, no kernel.
Future<int> runLink(Args args) async {
  final label = args.one('label');
  final listShortPath = args.optional('list-short-path');
  final manifestPaths = args.all('dep-manifest');
  final depShortPaths = args.all('dep-short-path');
  if (listShortPath != null && depShortPaths.length != manifestPaths.length) {
    throw const UsageException(
      'kernel_tool link: --dep-short-path and --dep-manifest must pair up',
    );
  }
  String runfilesPath(String shortPath) => shortPath.startsWith('../')
      ? shortPath.substring(3)
      : '${args.one('workspace-name')}/$shortPath';
  final listAt = listShortPath == null ? null : runfilesPath(listShortPath);
  final runfilesDirs = [for (final p in depShortPaths) runfilesPath(p)];
  final manifests = <String, Manifest>{
    for (var i = 0; i < manifestPaths.length; i++)
      ..._byLabel(
        Manifest.read(
          // Where the list names the module from; or, for a joined kernel,
          // where this action reads it, which need not be where the entry
          // compile saw it: one entry can serve several configurations.
          listAt != null
              ? runfilesDirs[i]
              : manifestPaths[i].replaceFirst(RegExp(r'\.json$'), ''),
          manifestPaths[i],
        ),
      ),
  };
  final selection =
      (jsonDecode(File(args.one('selection')).readAsStringSync())
              as Map)['modules']
          as List;
  final selected = <ModuleRef>[];
  for (final entry in selection.cast<Map<String, dynamic>>()) {
    final manifest = manifests[entry['label']];
    if (manifest == null) {
      stderr.writeln(
        '$label: the selection names ${entry['label']}, which is not among '
        'the manifests',
      );
      return 1;
    }
    selected.add(ModuleRef(manifest, manifest.modules[entry['id'] as int]));
  }

  final unique = uniqueModules(selected);
  if (unique.conflicts.isNotEmpty) {
    stderr.writeln(overlapMessages(label, unique.conflicts).join('\n'));
    return 1;
  }

  // The entry first: the VM runs the first `main` a component names, and a
  // module whose library declares one names it too.
  if (listAt != null) {
    final from = listAt.split('/')..removeLast();
    final kernels = [
      runfilesPath(args.one('entry-short-path')),
      for (final ref in unique.kept) ref.dillPath!,
    ];
    File(args.one('output')).writeAsStringSync(
      // The VM takes a line only once its newline is there.
      '#@dill\n${[for (final k in kernels) _relative(from, k)].join('\n')}\n',
    );
    return 0;
  }
  await concatenate([
    args.one('entry'),
    for (final ref in unique.kept) ref.dillPath!,
  ], args.one('output'));
  return 0;
}

Map<String, Manifest> _byLabel(Manifest manifest) => {manifest.label: manifest};

/// The path from the directory with segments [from] to runfiles path [to].
String _relative(List<String> from, String to) {
  final target = to.split('/');
  var common = 0;
  while (common < from.length &&
      common < target.length - 1 &&
      from[common] == target[common]) {
    common++;
  }
  return [
    for (var i = common; i < from.length; i++) '..',
    ...target.sublist(common),
  ].join('/');
}
