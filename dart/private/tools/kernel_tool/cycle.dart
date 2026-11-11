// Whether the packages a `dart_package_cycle` builds as one target are one
// dependency cycle, judged from what their files import.
import 'module_graph.dart';
import 'policy.dart';
import 'uris.dart';

/// Why the packages of [label] are not exactly one dependency cycle, or null
/// when they are.
///
/// A package depends on another when one of its [files] imports or exports a
/// `package:` URI of it, on any branch of a conditional import, as the import
/// check counts them. The packages are one cycle when each reaches every other
/// through those imports. A package outside them that a file imports and that
/// no dependency provides ([availablePackages]) may be what closes the cycle,
/// so the message names it.
String? cycleError({
  required String label,
  required List<CheckedFile> files,
  required PackageConfig config,
  required Set<String> ownPackages,
  required Set<String> availablePackages,
}) {
  final members = ownPackages.toList()..sort();
  final graph = {for (final m in members) m: <String>{}};
  // Imported packages no dependency provides, with the members importing them.
  final outside = <String, Set<String>>{};
  for (final f in files) {
    final from = config.packageOf(f.uri);
    if (from == null || !graph.containsKey(from)) continue;
    for (final d in f.directives.directives) {
      for (final uri in [d.uri, for (final c in d.configurations) c.uri]) {
        if (!uri.startsWith('package:')) continue;
        final to = packageNameOf(uri);
        if (to == null || to == from) continue;
        if (graph.containsKey(to)) {
          graph[from]!.add(to);
        } else if (!availablePackages.contains(to) &&
            !config.names.contains(to)) {
          outside.putIfAbsent(to, () => {}).add(from);
        }
      }
    }
  }

  final cycles = <List<String>>[];
  final loners = <String>[];
  for (final component in stronglyConnected<String>(
    members,
    (m) => graph[m]!.toList()..sort(),
  )) {
    component.sort();
    if (component.length == 1) {
      loners.add(component.single);
    } else {
      cycles.add(component);
    }
  }
  cycles.sort((a, b) => a.first.compareTo(b.first));
  loners.sort();
  if (cycles.length == 1 && loners.isEmpty) return null;

  final found = [
    for (final c in cycles)
      '${names(c)} import each other (${cyclePath(graph, c.first, c)})',
    if (loners.isNotEmpty)
      '${names(loners)} ${loners.length == 1 ? 'is' : 'are'} in no cycle'
          '${cycles.isEmpty ? '' : ' with the others'}',
  ];
  final remedies = <String>[];
  if (outside.isNotEmpty) {
    final candidates = outside.keys.toList()..sort();
    final via = [
      for (final p in candidates)
        '${names(outside[p]!.toList()..sort())} imports `$p`',
    ];
    remedies.add(
      '${via.join(', and ')}, which no dependency provides: if '
      '${candidates.length == 1 ? 'it imports' : 'they import'} the members '
      'in turn, add ${candidates.length == 1 ? 'it' : 'them'} to `members`.',
    );
  }
  final build = remedies.isEmpty ? 'Build' : 'Otherwise, build';
  if (cycles.isEmpty) {
    remedies.add(
      '$build each package as its own `dart_library`, and remove $label.',
    );
  } else {
    remedies.add(
      '$build ${[if (cycles.length > 1) 'each cycle as its own `dart_package_cycle`', if (loners.isNotEmpty) '${names(loners)} outside `members`, as '
            '${loners.length == 1 ? 'a `dart_library`' : '`dart_library` targets'}'].join(', and ')}.',
    );
  }
  return '$label builds ${names(members)} as one dependency cycle, but they '
      'are not one: ${found.join('; ')}. ${remedies.join(' ')}';
}

/// A shortest way from [start] back to itself through [members], as
/// `a -> b -> a`.
String cyclePath(
  Map<String, Set<String>> graph,
  String start,
  List<String> members,
) {
  final inside = members.toSet();
  final cameFrom = <String, String>{};
  var queue = [start];
  while (queue.isNotEmpty && !cameFrom.containsKey(start)) {
    final next = <String>[];
    for (final node in queue) {
      for (final dep in (graph[node] ?? const <String>{}).toList()..sort()) {
        if (inside.contains(dep) && !cameFrom.containsKey(dep)) {
          cameFrom[dep] = node;
          next.add(dep);
        }
      }
    }
    queue = next;
  }
  final path = [start];
  for (var node = cameFrom[start]!; node != start; node = cameFrom[node]!) {
    path.add(node);
  }
  path.add(start);
  return path.reversed.join(' -> ');
}

/// [packages] in backticks, as `a`, `b` and `c`.
String names(List<String> packages) {
  final quoted = [for (final p in packages) '`$p`'];
  if (quoted.length < 3) return quoted.join(' and ');
  return '${quoted.sublist(0, quoted.length - 1).join(', ')} and ${quoted.last}';
}
