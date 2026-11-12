import 'dart:io';

import 'args.dart';
import 'cycle.dart';
import 'directives.dart';
import 'policy.dart';
import 'sources.dart';
import 'uris.dart';

/// `check`: that what a target's files import is what its BUILD file depends
/// on. It needs no compiler and no platform, so it runs for every library, test
/// and binary, including a library no program or test compiles.
///
/// Each `import`, `export` and `part` is judged as written, the way the
/// compiler will resolve it (see `checkPolicy`). Every branch of a conditional
/// import counts: a library has to declare what each of them needs, whichever
/// the platform takes. The package config covers
/// the target's own package and every package it reaches, so the files of its
/// dependencies (`--dep-file`, a tree artifact's directory expanded) map to the
/// URIs importers use. With `--check-cycle`, the target's packages must be
/// one dependency cycle (`cycleError`). With `--generator-input`, the files are
/// what a code generator reads before it writes their parts, so their parts are
/// not judged. Writes the empty `--output` stamp when nothing is wrong;
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

  final files = [
    for (final file in readSources(args.all('src')))
      CheckedFile(
        path: file.path,
        rootPath: rootRelative(file.path, roots),
        uri: uriOf(file.path),
        directives: readDirectives(file.path, file.text),
      ),
  ];

  final violations = checkPolicy(
    label: label,
    files: files,
    config: config,
    availablePackages: args.all('available-package').toSet(),
    dependencyFiles: {
      for (final path in dartFiles(args.all('dep-file'))) uriOf(path),
    },
    checkLayering: args.flag('check-layering'),
    directPackages: args.all('direct-package').toSet(),
    ownPackages: ownPackages(args).keys.toSet(),
    suggestCycle: !args.flag('check-cycle'),
    checkParts: !args.flag('generator-input'),
  );
  final messages = [for (final v in violations) v.message];
  if (args.flag('check-cycle')) {
    final cycle = cycleError(
      label: label,
      files: files,
      config: config,
      ownPackages: ownPackages(args).keys.toSet(),
      availablePackages: args.all('available-package').toSet(),
    );
    if (cycle != null) messages.add(cycle);
  }
  if (messages.isNotEmpty) {
    err.writeln(messages.join('\n'));
    return 1;
  }
  File(args.one('output')).writeAsStringSync('');
  return 0;
}
