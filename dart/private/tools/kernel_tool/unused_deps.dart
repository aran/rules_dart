// The converse of strict deps: a dependency in a target's `deps` that none of
// its files names. Each such edge widens what a change to the dependency
// rebuilds and reruns, and nothing the target compiles needs it.
import 'dart:convert';

import 'args.dart';
import 'policy.dart';
import 'uris.dart';

/// The Bazel feature that turns this check off for a target, its package or
/// the build.
const unusedDepsFeature = 'dart_unused_deps';

/// What removes the deps the check finds, run with target patterns.
const unusedDepsFixer = 'bazel run @rules_dart//dart/unused_deps --';

/// One entry of the target's `deps`, as the rule hands it to the check.
class DeclaredDep {
  const DeclaredDep({
    required this.label,
    required this.files,
    required this.packages,
    required this.reach,
    String? display,
    this.exempt = false,
  }) : display = display ?? label;

  /// Its canonical label, which identifies it.
  final String label;

  /// Its label as the dependent's BUILD file can write it.
  final String display;

  /// The URIs of its own files ([PackageConfig.uriFor]); empty for a target
  /// with no sources of its own, which only passes its dependencies on.
  final Set<String> files;

  /// The packages it contributes itself.
  final Set<String> packages;

  /// Every package it reaches, its own included.
  final Set<String> reach;

  /// Whether its rule exempts it: one used without an import (a plugin,
  /// registered by native code), or whose packages bring native assets or a
  /// hook. It still holds its files, so an import of one names it and no
  /// other dependency; it is never reported itself.
  final bool exempt;

  /// Whether it has no files of its own and only passes its dependencies on.
  bool get isFacade => files.isEmpty;
}

/// The [deps] that no directive of [files] names, in the order of [deps].
///
/// Every `import` and `export`, on every branch of a conditional one, counts
/// as a use, as every one of them has to be declared. A doc import does not:
/// it loads nothing, and analysis needs nothing of it. A URI names the
/// dependency that holds that file. One no dependency holds (a package whose
/// files are not listed, or one a dependency passes on) names each
/// dependency that contributes the package, or failing that, each that
/// passes it on: removing any of those would leave the import unprovided, so
/// none of them is reported. When [layered] (the layering check runs), only a
/// façade (a dependency with no files of its own) passes a package on, as
/// that check accepts nothing else a dependency only reaches; without it,
/// each dependency reaching the package does. A file of the target itself
/// names no dependency, unless it is in a package none of [ownPackages] is.
List<DeclaredDep> unusedDeps({
  required String label,
  required List<CheckedFile> files,
  required PackageConfig config,
  LoadedUri? loaded,
  required List<DeclaredDep> deps,
  Set<String> ownPackages = const {},
  bool layered = true,
}) {
  final resolve = loaded ?? judgedUri(config, label);
  // A file of the target in a package it states names no dependency; one in
  // a package only a dependency contributes (an executable's `srcs` under a
  // façade's package) names that dependency, through which it resolves.
  bool stated(String uri) {
    final name = packageNameOf(uri);
    return name == null || ownPackages.contains(name);
  }

  final held = {
    for (final f in files)
      if (stated(f.uri)) f.uri,
  };
  final used = <String>{};
  void use(String uri) {
    if (uri.startsWith('dart:') || held.contains(uri)) return;
    final holders = [
      for (final d in deps)
        if (d.files.contains(uri)) d.label,
    ];
    if (holders.isNotEmpty) {
      used.addAll(holders);
      return;
    }
    final name = packageNameOf(uri);
    if (name == null) return;
    final owners = [
      for (final d in deps)
        if (d.packages.contains(name)) d.label,
    ];
    used.addAll(
      owners.isNotEmpty
          ? owners
          : [
              for (final d in deps)
                if ((d.isFacade || !layered) && d.reach.contains(name)) d.label,
            ],
    );
  }

  for (final f in files) {
    for (final d in f.directives.directives) {
      for (final written in [d.uri, for (final c in d.configurations) c.uri]) {
        if (resolve(written, f) case final uri?) {
          use(uri);
        }
      }
    }
  }
  return [
    for (final d in deps)
      if (!used.contains(d.label) && !d.exempt) d,
  ];
}

/// The failure for [unused], listed by [dependent], the BUILD file's entry
/// that states them: a line for each, as that file can write it.
String unusedDepsMessage(String dependent, List<DeclaredDep> unused) {
  final package = dependent.substring(0, dependent.lastIndexOf(':'));
  return [
    '$dependent: no file imports or exports these deps:',
    for (final d in unused) '  ${d.display}',
    '$unusedDepsFixer $package:all removes them. One used without an import '
        'is exempt when its rule returns DartUsedWithoutImportInfo; '
        'features = ["-$unusedDepsFeature"] turns the check off.',
  ].join('\n');
}

/// What `--report` writes, for [unusedDepsFixer]: the target's [label], the
/// BUILD file's entry that states its `deps` ([dependent]), the canonical
/// label of each of [unused], what of its `srcs` main never reaches and the
/// BUILD file can drop ([UnreachedSrcs.named]), the canonical label of each
/// of [unreachedOnly], the deps only those files import, the exec path of
/// each file the program does not load though its `srcs` entry stays
/// ([UnreachedSrcs.notLoaded]), and each import, export or part of the
/// target's files that the check refuses ([refused]), whose uses are not
/// known.
String unusedDepsReport(
  String label,
  String dependent,
  List<DeclaredDep> unused, {
  UnreachedSrcs unreached = const UnreachedSrcs(),
  List<DeclaredDep> unreachedOnly = const [],
  List<({String path, String uri})> refused = const [],
}) => jsonEncode({
  'label': label,
  'dependent': dependent,
  'unused': [for (final d in unused) d.label],
  'unreached': unreached.named,
  'unreachedOnly': [for (final d in unreachedOnly) d.label],
  'notLoaded': [for (final f in unreached.notLoaded) f.path],
  'refused': [
    for (final r in refused) {'path': r.path, 'uri': r.uri},
  ],
});

/// The `--dep` values of `check`: each `<label>\t<kind>\t<value>...`, where
/// the kind is `file` (a path, a directory standing for its `.dart` files),
/// `package` (one it contributes), `reach` (one it reaches), `name` (its
/// label as the dependent's BUILD file can write it, one value) or `exempt`
/// (never reported, no value), in any number of values for one label.
List<DeclaredDep> parseDeclaredDeps(
  List<String> values,
  String Function(String path) uriOf,
  List<String> Function(List<String> paths) expand,
) {
  final order = <String>[];
  final files = <String, Set<String>>{};
  final packages = <String, Set<String>>{};
  final reach = <String, Set<String>>{};
  final names = <String, String>{};
  final exempt = <String>{};
  for (final value in values) {
    final fields = value.split('\t');
    if (fields.length < 2) {
      throw UsageException('kernel_tool check: malformed --dep $value');
    }
    final label = fields[0];
    if (!files.containsKey(label)) {
      order.add(label);
      files[label] = {};
      packages[label] = {};
      reach[label] = {};
    }
    final rest = fields.skip(2).where((v) => v.isNotEmpty).toList();
    switch (fields[1]) {
      case 'file':
        files[label]!.addAll(expand(rest).map(uriOf));
      case 'package':
        packages[label]!.addAll(rest);
      case 'reach':
        reach[label]!.addAll(rest);
      case 'name' when rest.length == 1:
        names[label] = rest.single;
      case 'exempt' when rest.isEmpty:
        exempt.add(label);
      default:
        throw UsageException('kernel_tool check: malformed --dep $value');
    }
  }
  return [
    for (final label in order)
      DeclaredDep(
        label: label,
        files: files[label]!,
        packages: packages[label]!,
        reach: reach[label]!,
        display: names[label],
        exempt: exempt.contains(label),
      ),
  ];
}

/// One entry of an executable's `srcs` that is not simply a file: a filegroup,
/// a rule's outputs, a tree artifact. The BUILD file can drop it, but not one
/// of its files.
class SrcEntry {
  const SrcEntry(this.label, this.paths);

  /// The entry as the BUILD file writes it.
  final String label;

  /// The exec paths of its Dart files.
  final Set<String> paths;
}

/// The fields of a `--src-entry` value, `<label>\t<path>...`: the label, then
/// the paths, a directory standing for its `.dart` files.
List<String> srcEntryFields(String value) {
  final fields = value.split('\t');
  if (fields.length < 2) {
    throw UsageException('kernel_tool check: malformed --src-entry $value');
  }
  return fields;
}

/// What an executable's `srcs` hold that its program does not load.
class UnreachedSrcs {
  const UnreachedSrcs({
    this.files = const [],
    this.entries = const [],
    this.notLoaded = const [],
  });

  /// Files listed by themselves: each can leave `srcs`.
  final List<CheckedFile> files;

  /// Entries none of whose files is reached: each can leave `srcs`.
  final List<({SrcEntry entry, List<CheckedFile> files})> entries;

  /// The unreached files of entries that stay, because another of their files
  /// is reached. They are no part of this program: what they import is neither
  /// a use of its deps nor something its deps must provide.
  final List<CheckedFile> notLoaded;

  /// What holds with the `dart_unused_deps` feature off, which turns off the
  /// failure and leaves what the program loads as it is: nothing is reported,
  /// and an entry none of whose files is reached stays, so its files are like
  /// the [notLoaded] ones. A file listed by itself stays judged and analyzed:
  /// it belongs to this target alone, so no other program answers for it.
  UnreachedSrcs get unenforced => UnreachedSrcs(
    notLoaded: [...notLoaded, for (final e in entries) ...e.files],
  );

  /// The files to report: those of [files] and of [entries].
  Iterable<CheckedFile> get reported => [
    ...files,
    for (final e in entries) ...e.files,
  ];

  bool get isEmpty => files.isEmpty && entries.isEmpty;

  /// What to remove from `srcs`, each as the failure names it.
  List<String> get named => [
    for (final f in files) f.path,
    for (final e in entries)
      '${e.entry.label} (${e.files.map((f) => f.path).join(', ')})',
  ];
}

/// What of [files] no file of [entries] reaches through `import`, `export` and
/// `part` directives, on every branch of a conditional one, sorted by what the
/// BUILD file can do about it ([srcEntries]). An unreached file is compiled
/// into nothing the program loads, so its imports must not count as uses of
/// the program's deps. A doc import reaches nothing, as it loads nothing.
UnreachedSrcs unreachedSrcs({
  required String label,
  required List<CheckedFile> files,
  required List<CheckedFile> entries,
  required PackageConfig config,
  LoadedUri? loaded,
  List<SrcEntry> srcEntries = const [],
}) {
  final resolve = loaded ?? judgedUri(config, label);
  final byUri = {for (final f in files) f.uri: f};
  final reached = <String>{};
  final pending = [...entries];
  for (final e in entries) {
    reached.add(e.uri);
  }
  while (pending.isNotEmpty) {
    final f = pending.removeLast();
    final written = [
      for (final d in f.directives.directives) ...[
        d.uri,
        for (final c in d.configurations) c.uri,
      ],
      ...f.directives.parts,
    ];
    for (final w in written) {
      final uri = resolve(w, f);
      if (uri == null || !reached.add(uri)) continue;
      if (byUri[uri] case final next?) pending.add(next);
    }
  }
  final unreached = [
    for (final f in files)
      if (!reached.contains(f.uri)) f,
  ];
  final unreachedPaths = {for (final f in unreached) f.path};
  final held = {for (final f in files) f.path};
  final dropped = <({SrcEntry entry, List<CheckedFile> files})>[];
  final kept = <String>{};
  for (final entry in srcEntries) {
    final members = entry.paths.where(held.contains).toSet();
    if (members.isEmpty) continue;
    if (members.every(unreachedPaths.contains)) {
      dropped.add((
        entry: entry,
        files: [
          for (final f in unreached)
            if (members.contains(f.path)) f,
        ],
      ));
    } else {
      kept.addAll(members.where(unreachedPaths.contains));
    }
  }
  final inEntry = {for (final e in srcEntries) ...e.paths};
  return UnreachedSrcs(
    files: [
      for (final f in unreached)
        if (!inEntry.contains(f.path)) f,
    ],
    entries: dropped,
    notLoaded: [
      for (final f in unreached)
        if (kept.contains(f.path)) f,
    ],
  );
}

/// The failure for [unreached], what [dependent]'s `srcs` hold that its `main`
/// never loads.
String unreachedFilesMessage(String dependent, UnreachedSrcs unreached) => [
  '$dependent: main never imports, exports or includes as a part these '
      'srcs, so the program never loads them, while what they import '
      'counts as used:',
  for (final n in unreached.named) '  $n',
  'Remove them from srcs; a file read at run time belongs in data. '
      'features = ["-$unusedDepsFeature"] turns the check off.',
].join('\n');

/// The analysis project's `analysis_options.yaml`, [options], also excluding
/// each of [paths]: exec paths of source files, staged under `src/`.
String optionsExcluding(String options, List<String> paths) {
  if (paths.isEmpty) return options;
  final lines = [for (final p in paths) '    - "src/$p"'].join('\n');
  const section = 'analyzer:\n  exclude:\n';
  final at = options.indexOf(section);
  if (at < 0) return '$options$section$lines\n';
  final end = at + section.length;
  return '${options.substring(0, end)}$lines\n${options.substring(end)}';
}
