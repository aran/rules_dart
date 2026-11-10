// Prepares a release of the module in the checkout it runs in, for
// bazel-contrib's release_ruleset workflow, which calls the repository's
// `.github/workflows/release_prep.sh <tag>` and publishes what it prints as
// the release notes.
//
//   bazel run @overhead//release:prep -- vX.Y.Z
//
// Writes `<module>-<tag>.tar.gz`, the source archive at the tag, in the
// checkout root, and prints a `bazel_dep` for each module the release
// publishes (`moduleRoots` in `.bcr/config.yml`) followed by the notes the
// `Changelog:` trailers since the previous version tag make. A first release,
// with no previous version tag, has no notes.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'modules.dart';
import 'notes_range.dart';

final _version = RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+$');

Future<void> main(List<String> args) async {
  if (args.length != 3 || !_version.hasMatch(args[2])) {
    stderr.writeln('usage: prep vX.Y.Z');
    exit(2);
  }
  final repo = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (repo == null) {
    stderr.writeln('prep: run me with `bazel run`');
    exit(2);
  }
  final runfiles = Runfiles.create();
  final gitCliff = runfiles.rlocation(args[0]);
  final config = runfiles.rlocation(args[1]);
  final tag = args[2];
  final version = tag.substring(1);

  final module = moduleName(File('$repo/MODULE.bazel').readAsStringSync());
  if (module == null) {
    stderr.writeln('prep: no module(name = ...) in $repo/MODULE.bazel');
    exit(2);
  }
  final List<String> released;
  try {
    released = releasedModules(repo);
  } on FormatException catch (e) {
    stderr.writeln('prep: ${e.message}');
    exit(2);
  }

  // The prefix GitHub gives its own source archives, so that a user can switch
  // between the two without changing `strip_prefix`. What the archive leaves
  // out is configured by `export-ignore` in the repository's .gitattributes.
  await git(repo, [
    'archive',
    '--format=tar.gz',
    '--prefix=$module-$version/',
    '--output=$module-$tag.tar.gz',
    tag,
  ]);

  stdout.write(installSnippet(released, version));

  // The release job checks out the tag alone, without history or other tags.
  final shallow = await git(repo, ['rev-parse', '--is-shallow-repository']);
  await git(repo, [
    'fetch',
    '--quiet',
    '--tags',
    if (shallow.trim() == 'true') '--unshallow',
    'origin',
  ]);
  final range = await notesRange(repo, tag);
  if (range == null) return;

  final cliff = await Process.start(gitCliff, [
    '--workdir',
    repo,
    '--repository',
    repo,
    '--config',
    config,
    '--strip',
    'header',
    range,
  ], mode: ProcessStartMode.inheritStdio);
  exit(await cliff.exitCode);
}
