import 'dart:io';

import 'args.dart';
import 'directives.dart';
import 'policy.dart';
import 'sources.dart';
import 'uris.dart';

/// `check`: that what a target's files import is what its BUILD file depends
/// on. It needs no compiler and no platform, so it runs for every library, test
/// and binary, including a library no program or test compiles.
///
/// Every branch of a conditional import counts: a library has to declare what
/// each of them needs, whichever the platform takes. The package config covers
/// the target's own package and every package it reaches, so the files of its
/// dependencies (`--dep-file`, a tree artifact's directory expanded) map to the
/// URIs importers use. Writes the empty `--output` stamp when nothing is wrong;
/// otherwise prints every violation to [err] and returns 1.
Future<int> runCheck(Args args, {required StringSink err}) async {
  final label = args.one('label');
  final roots = args.all('multi-root');
  final configPath = args.one('package-config');
  final config = PackageConfig.parse(
    File(configPath).readAsStringSync(),
    rootRelative(configPath, roots),
  );

  String uriOf(String path) => config.uriFor(rootRelative(path, roots));

  final libraries = <String, ImportingFile>{};
  final partFiles = <String>{};
  for (final file in readSources(args.all('src'))) {
    final uri = uriOf(file.path);
    final directives = readDirectives(file.path, file.text);
    if (directives.isPart) {
      partFiles.add(uri);
      continue;
    }
    libraries[uri] = ImportingFile(file.path, [
      for (final d in directives.directives)
        ...resolveImport(d, uri, null, config).candidates,
    ]);
  }

  final violations = checkPolicy(
    label: label,
    libraries: libraries,
    partFiles: partFiles,
    config: config,
    availablePackages: args.all('available-package').toSet(),
    dependencyFiles: {
      for (final path in dartFiles(args.all('dep-file'))) uriOf(path),
    },
    checkLayering: args.flag('check-layering'),
    directPackages: args.all('direct-package').toSet(),
    ownPackage: args.optional('package-name'),
  );
  if (violations.isNotEmpty) {
    err.writeln(violations.map((v) => v.message).join('\n'));
    return 1;
  }
  File(args.one('output')).writeAsStringSync('');
  return 0;
}
