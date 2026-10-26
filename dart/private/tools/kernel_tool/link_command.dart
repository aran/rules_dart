import 'dart:convert';
import 'dart:io';

import 'args.dart';
import 'compile.dart';
import 'manifest.dart';

/// `link`: the entry and the modules the entry selected joined into one file
/// the VM can run. A library two selected modules both define is refused: the
/// front end silently used one copy, and which depended on the order.
Future<int> runLink(Args args) async {
  final label = args.one('label');
  final manifests = {
    for (final path in args.all('dep-manifest'))
      ..._byLabel(
        Manifest.read(path.replaceFirst(RegExp(r'\.json$'), ''), path),
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
  await concatenate([
    args.one('entry'),
    // Where this action sees the module, which need not be where the entry
    // compile saw it: one entry can serve several configurations.
    for (final ref in unique.kept) ref.dillPath!,
  ], args.one('output'));
  return 0;
}

Map<String, Manifest> _byLabel(Manifest manifest) => {manifest.label: manifest};
