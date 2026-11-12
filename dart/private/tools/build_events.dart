// What a `bazel build` made, read from its event file
// (`--build_event_json_file`), the interface Bazel offers for "which files did
// this build make".
import 'dart:convert';
import 'dart:io';

/// The files of the output [group], by the build event file at [events], and
/// how many targets the build configured.
///
/// A target's completion event, or an aspect's for it, lists its output
/// groups by file set, file sets nest, and each file is named relative to the
/// exec root the build's workspace event gives. An aspect's event names the
/// aspect by the file that defines it, not the one it was requested through,
/// so the group, which one aspect or one kind of target makes, is what picks
/// the events.
({int configured, List<String> files}) groupFiles(String events, String group) {
  final sets = <String, Map<String, dynamic>>{};
  final roots = <String>[];
  var configured = 0;
  String? execRoot;
  for (final line in File(events).readAsLinesSync()) {
    if (line.isEmpty) continue;
    final event = jsonDecode(line) as Map<String, dynamic>;
    final id = event['id'] as Map<String, dynamic>;
    if (id['namedSet'] case {'id': final String setId}) {
      sets[setId] = event['namedSetOfFiles'] as Map<String, dynamic>;
    } else if (event['workspaceInfo'] case {
      'localExecRoot': final String root,
    }) {
      execRoot = root;
    } else if (id.containsKey('targetConfigured')) {
      configured++;
    } else if (id.containsKey('targetCompleted')) {
      final completed = event['completed'] as Map<String, dynamic>?;
      for (final g in (completed?['outputGroup'] as List? ?? const [])) {
        if (g['name'] != group) continue;
        for (final s in (g['fileSets'] as List? ?? const [])) {
          roots.add(s['id'] as String);
        }
      }
    }
  }
  if (execRoot == null) {
    throw FormatException('$events names no exec root');
  }

  final files = <String>{};
  final seen = <String>{};
  final pending = [...roots];
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (!seen.add(id)) continue;
    final set = sets[id];
    if (set == null) throw FormatException('$events lacks file set $id');
    for (final f in (set['files'] as List? ?? const [])) {
      final parts = [
        execRoot,
        ...(f['pathPrefix'] as List? ?? const []).cast<String>(),
        ...(f['name'] as String).split('/'),
      ];
      files.add(parts.join(Platform.pathSeparator));
    }
    for (final s in (set['fileSets'] as List? ?? const [])) {
      pending.add(s['id'] as String);
    }
  }
  for (final file in files) {
    if (!File(file).existsSync()) {
      // Left remote, as `--remote_download_outputs=minimal` does with
      // every output.
      throw FormatException(
        'the build made $file but did not download it; pass '
        '--remote_download_outputs=toplevel',
      );
    }
  }
  return (configured: configured, files: files.toList()..sort());
}
