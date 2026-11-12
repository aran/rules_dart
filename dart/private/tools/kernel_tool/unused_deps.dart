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
/// as a use, as every one of them has to be declared. A URI names the
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
  required List<DeclaredDep> deps,
  Set<String> ownPackages = const {},
  bool layered = true,
}) {
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
        if (compiledUri(written, f, config, label).uri case final uri?) {
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
/// BUILD file's entry that states its `deps` ([dependent]), and the
/// canonical label of each of [unused].
String unusedDepsReport(
  String label,
  String dependent,
  List<DeclaredDep> unused,
) => jsonEncode({
  'label': label,
  'dependent': dependent,
  'unused': [for (final d in unused) d.label],
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
