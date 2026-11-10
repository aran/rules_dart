// How a target's libraries are split into kernel modules: a port of
// `build_modules`' fine strategy (`meta_module.dart`, `modules.dart`).
//
// A module is a strongly connected component of the libraries' import and
// export graph: edges inside the target only, conditional imports resolved for
// the platform. Parts always go with their library.
//
// `build_modules` also has a coarse strategy, which merges the components only
// one public library reaches into that library. It saves a browser module
// loads; for kernel that is concatenated, it buys nothing, and it makes a
// private library unusable on a platform its public importer does not run on.
import 'dart:math' as math;

import 'directives.dart';
import 'sources.dart';
import 'uris.dart';

/// A library of the target being compiled.
class LibraryNode {
  LibraryNode({
    required this.uri,
    required this.path,
    required this.imports,
    required this.parts,
    this.fileUris = const [],
  });

  final String uri;

  /// The exec path of the file, as shown in messages.
  final String path;

  /// Resolved against the platform, URIs in [PackageConfig.canonical] form.
  final List<ResolvedImport> imports;

  /// URIs of the part files that library names and the target holds.
  final List<String> parts;

  /// The `file:` URIs it or its parts name, as written, in any branch: files
  /// the compiler would read off the host, whatever the build declares.
  final List<String> fileUris;

  /// The libraries this one pulls in, `dart:` ones apart.
  Iterable<String> get reached sync* {
    for (final import in imports) {
      for (final uri in import.reached) {
        if (!uri.startsWith('dart:')) yield uri;
      }
    }
  }

  /// The `dart:` libraries imported (by the branch taken) that [supported]
  /// lacks.
  Iterable<String> unsupportedDart(Set<String> supported) sync* {
    for (final import in imports) {
      if (import.selected case final uri? when uri.startsWith('dart:')) {
        if (!supported.contains(uri.substring('dart:'.length))) yield uri;
      }
    }
  }
}

/// A set of libraries compiled together.
class PlannedModule {
  PlannedModule({
    required this.libraries,
    required this.parts,
    required this.deps,
    required this.unsupported,
    this.fileUris = const [],
  });

  /// Library URIs, sorted; parts are not listed.
  final List<String> libraries;
  final List<String> parts;

  /// Library URIs outside the module that its libraries import or export.
  final List<String> deps;

  /// One line for each import of a `dart:` library the platform lacks.
  final List<String> unsupported;

  /// Each `file:` URI a library names, with the library.
  final List<String> fileUris;
}

/// The strongly connected components of the graph over [nodes], each after
/// every component it has an edge into. [edges] may name only nodes.
List<List<T>> stronglyConnected<T>(
  Iterable<T> nodes,
  Iterable<T> Function(T) edges,
) {
  final index = <T, int>{};
  final low = <T, int>{};
  final stack = <T>[];
  final onStack = <T>{};
  final components = <List<T>>[];
  void visit(T v) {
    index[v] = low[v] = index.length;
    stack.add(v);
    onStack.add(v);
    for (final w in edges(v)) {
      if (!index.containsKey(w)) {
        visit(w);
        low[v] = math.min(low[v]!, low[w]!);
      } else if (onStack.contains(w)) {
        low[v] = math.min(low[v]!, index[w]!);
      }
    }
    if (low[v] == index[v]) {
      final component = <T>[];
      T w;
      do {
        w = stack.removeLast();
        onStack.remove(w);
        component.add(w);
      } while (w != v);
      components.add(component);
    }
  }

  for (final node in nodes) {
    if (!index.containsKey(node)) visit(node);
  }
  return components;
}

/// The libraries' modules, dependencies first, ordered the same way every run.
List<PlannedModule> planModules({
  required Map<String, LibraryNode> libraries,
  required Set<String> supported,
}) {
  final uris = libraries.keys.toList()..sort();
  final components = stronglyConnected<String>(uris, (uri) sync* {
    for (final dep in (libraries[uri]!.reached.toSet().toList()..sort())) {
      if (libraries.containsKey(dep)) yield dep;
    }
  });
  return [
    for (final component in components)
      _plannedModule([
        for (final uri in component..sort()) libraries[uri]!,
      ], supported),
  ];
}

PlannedModule _plannedModule(
  List<LibraryNode> component,
  Set<String> supported,
) {
  final parts = {for (final lib in component) ...lib.parts};
  final own = {for (final lib in component) lib.uri, ...parts};
  return PlannedModule(
    libraries: [for (final lib in component) lib.uri],
    parts: parts.toList()..sort(),
    deps: ({
      for (final lib in component) ...lib.reached,
    }..removeAll(own)).toList()..sort(),
    unsupported: [
      for (final lib in component)
        for (final dart in lib.unsupportedDart(supported))
          '${lib.uri} imports $dart',
    ],
    fileUris: [
      for (final lib in component)
        for (final uri in lib.fileUris) "'$uri' (in ${lib.uri})",
    ],
  );
}

/// The libraries and part files among a target's [sources].
class Sources {
  Sources(this.files, this.libraries, this.partFiles);

  /// Every file, by the URI importers know it by.
  final Map<String, SourceFile> files;
  final Map<String, LibraryNode> libraries;

  /// Part files, whether or not a library of the target names them.
  final Set<String> partFiles;
}

Sources readLibraries({
  required List<SourceFile> sources,
  required List<String> roots,
  required PackageConfig config,
  required Set<String> supported,
}) {
  final files = <String, SourceFile>{};
  final directives = <String, Directives>{};
  for (final file in sources) {
    final uri = config.uriFor(rootRelative(file.path, roots));
    files[uri] = file;
    directives[uri] = readDirectives(file.path, file.text);
  }
  final partFiles = {
    for (final e in directives.entries)
      if (e.value.isPart) e.key,
  };
  final libraries = <String, LibraryNode>{};
  for (final entry in directives.entries) {
    final uri = entry.key;
    if (entry.value.isPart) continue;
    // A part belongs to the library that names it, however the part spells
    // `part of`.
    final parts = [
      for (final part in entry.value.parts)
        config.canonical(resolveUri(uri, part)),
    ];
    final held = [
      for (final part in parts)
        if (partFiles.contains(part)) part,
    ];
    libraries[uri] = LibraryNode(
      uri: uri,
      path: files[uri]!.path,
      imports: [
        for (final d in entry.value.directives)
          resolveImport(d, uri, supported, config),
      ],
      parts: held,
      fileUris: [
        for (final d in [entry.value, for (final p in held) directives[p]!])
          ..._fileUris(d),
      ],
    );
  }
  return Sources(files, libraries, partFiles);
}

Iterable<String> _fileUris(Directives directives) => [
  for (final d in directives.directives) ...[
    d.uri,
    for (final c in d.configurations) c.uri,
  ],
  ...directives.parts,
].where((written) => Uri.tryParse(written)?.isScheme('file') ?? false);
