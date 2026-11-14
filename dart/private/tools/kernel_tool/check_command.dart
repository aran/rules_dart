import 'dart:convert';
import 'dart:io';

import 'args.dart';
import 'cycle.dart';
import 'directives.dart';
import 'policy.dart';
import 'sources.dart';
import 'unused_deps.dart';
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
/// not judged. With `--check-unused`, every `--dep` must be named by some
/// directive of the files or of a `--use-src`, a file built from
/// the deps that is not judged itself: the package's link hook, or one the rule
/// writes (`unusedDeps`), whose imports count however the compile resolves them
/// (`unjudgedUri`); the failure names them as `--dependent`, the BUILD file's
/// entry that states them, writes them. With an `--entry` (an executable's
/// `main`), what the program loads is worked out from it and from each
/// `--use-src` (`unreachedSrcs`), with or without `--check-unused`. A
/// `--src-entry` is a `srcs` entry the BUILD file can drop only whole: when
/// some of its files are reached, the others are no part of the program, and
/// neither count as uses nor are judged. With `--check-unused`, every other
/// file must be reached, as an unreached file's imports would otherwise count
/// as uses of deps the program never loads, and an entry fails when none of its
/// files is. Without it nothing fails for being unreached, and the files of
/// such an entry are no part of the program either (`UnreachedSrcs.unenforced`).
/// Beside a refused import, a file is judged only when every refused URI can be
/// followed to what it would load once fixed. With `--report`, the unused-deps
/// check, the unreached files and the refused imports are written there instead
/// of failing (`unusedDepsReport`), the deps only unreached files import apart.
/// Writes the empty `--output` stamp when nothing is wrong; otherwise prints
/// every violation to [err] and returns 1.
Future<int> runCheck(Args args, {required StringSink err}) async {
  final label = args.one('label');
  final roots = args.all('multi-root');
  final configPath = args.one('package-config');
  final config = PackageConfig.parse(
    File(configPath).readAsStringSync(),
    rootRelative(configPath, roots),
  );

  String uriOf(String path) => config.uriFor(rootRelative(path, roots));

  CheckedFile checked(SourceFile file) => CheckedFile(
    path: file.path,
    rootPath: rootRelative(file.path, roots),
    uri: uriOf(file.path),
    directives: readDirectives(file.path, file.text),
  );

  final files = [
    for (final file in readSources(args.all('src'))) checked(file),
  ];
  // Files built from the target's deps that are not its own to check: its
  // package's link hook, and what the rule writes (a bootstrap).
  final uses = [
    for (final file in readSources(args.all('use-src'))) checked(file),
  ];

  final loaded = unjudgedUri(config, label, roots, {
    for (final f in uses) f.path,
  });

  // An executable's srcs its main never reaches, or none when it has no main
  // or what main reaches is not known.
  UnreachedSrcs findUnreached() {
    if (args.all('entry').isEmpty) return const UnreachedSrcs();
    final fixed = anyLoadedUri(config, label, roots);
    final held = {for (final f in files) f.path};
    // A refused URI loads nothing yet, so it is followed to where it would
    // load from once fixed, and only a file nothing reaches is reported
    // beside it. One that cannot be followed (an absolute path, a file:
    // URI) leaves what main reaches unknown: none is reported until the
    // refusal is fixed.
    var known = true;
    String? lenient(String written, CheckedFile file) {
      if (loaded(written, file) case final uri?) return uri;
      if (!held.contains(file.path) ||
          compiledUri(written, file, config, label).refusal == null) {
        return null;
      }
      final uri = fixed(written, file);
      if (uri == null) known = false;
      return uri;
    }

    final entries = args.all('entry').toSet();
    final srcEntries = [
      for (final value in args.all('src-entry')) srcEntryFields(value),
    ];
    final named = {for (final e in srcEntries) ...e.skip(1)};
    final found = unreachedSrcs(
      label: label,
      files: files,
      // The files built from the deps start programs too: a bootstrap runs
      // main, and the link hook runs at build time on the package's lib/.
      entries: [
        for (final f in files)
          if (entries.contains(f.path)) f,
        ...uses,
      ],
      config: config,
      loaded: lenient,
      srcEntries: [
        for (final e in srcEntries)
          SrcEntry(e.first, dartFiles(e.sublist(1)).toSet()),
        // A directory no entry names is one all the same.
        for (final src in args.all('src'))
          if (!named.contains(src) && Directory(src).existsSync())
            SrcEntry(src, dartFiles([src]).toSet()),
      ],
    );
    return known ? found : const UnreachedSrcs();
  }

  final reach = findUnreached();
  final unreached = args.flag('check-unused') ? reach : reach.unenforced;
  final notLoaded = {for (final f in unreached.notLoaded) f.path};
  // The files judged: all but those of the target no part of its program.
  final judged = [
    for (final f in files)
      if (!notLoaded.contains(f.path)) f,
  ];

  List<DeclaredDep> findUnused(List<CheckedFile> counted) => unusedDeps(
    label: label,
    files: [...counted, ...uses],
    config: config,
    loaded: loaded,
    deps: parseDeclaredDeps(args.all('dep'), uriOf, dartFiles),
    ownPackages: ownPackages(args).keys.toSet(),
    layered: args.flag('check-layering'),
  );
  // A generator's input names parts it has yet to write.
  final checkParts = !args.flag('generator-input');
  final violations = checkPolicy(
    label: label,
    files: judged,
    config: config,
    availablePackages: args.all('available-package').toSet(),
    dependencyFiles: {
      for (final path in dartFiles(args.all('dep-file'))) uriOf(path),
    },
    checkLayering: args.flag('check-layering'),
    directPackages: args.all('direct-package').toSet(),
    ownPackages: ownPackages(args).keys.toSet(),
    suggestCycle: !args.flag('check-cycle'),
    checkParts: checkParts,
  );

  if (args.optional('report') case final report?) {
    // What `unusedDepsFixer` removes; the other checks are the validation's.
    // A dep only the unreached files import is the user's to judge: removing
    // it is wrong once they import the file.
    final unused = findUnused(judged);
    final dropped = {for (final f in unreached.reported) f.path};
    final reached = [
      for (final f in judged)
        if (!dropped.contains(f.path)) f,
    ];
    final removed = {for (final d in unused) d.label};
    File(report).writeAsStringSync(
      unusedDepsReport(
        label,
        args.one('dependent'),
        unused,
        unreached: unreached,
        unreachedOnly: [
          if (!unreached.isEmpty)
            for (final d in findUnused(reached))
              if (!removed.contains(d.label)) d,
        ],
        // A refused URI loads nothing, yet may name a dep's file: the
        // fixer removes nothing while there is one.
        refused: [
          for (final f in judged)
            for (final written in [
              for (final d in f.directives.directives) ...[
                d.uri,
                for (final c in d.configurations) c.uri,
              ],
              if (checkParts) ...f.directives.parts,
            ])
              if (compiledUri(written, f, config, label).refusal != null)
                (path: f.path, uri: written),
        ],
      ),
    );
    return 0;
  }

  final messages = [for (final v in violations) v.message];
  if (args.flag('check-cycle')) {
    final cycle = cycleError(
      label: label,
      files: judged,
      config: config,
      ownPackages: ownPackages(args).keys.toSet(),
      availablePackages: args.all('available-package').toSet(),
    );
    if (cycle != null) messages.add(cycle);
  }
  if (!unreached.isEmpty) {
    messages.add(unreachedFilesMessage(args.one('dependent'), unreached));
  }
  if (args.flag('check-unused')) {
    final unused = findUnused(judged);
    if (unused.isNotEmpty) {
      messages.add(unusedDepsMessage(args.one('dependent'), unused));
    }
  }
  if (messages.isNotEmpty) {
    err.writeln(messages.join('\n'));
    return 1;
  }
  File(args.one('output')).writeAsStringSync('');
  return 0;
}

/// `exclude-unloaded`: the `--options` file of an executable's analysis
/// project, written to `--output` also excluding the files `--report` says its
/// program does not load. What they import need not resolve here; the programs
/// that load them analyze them.
int runExcludeUnloaded(Args args) {
  final report = jsonDecode(
    File(args.one('report')).readAsStringSync(),
  ) as Map<String, Object?>;
  File(args.one('output')).writeAsStringSync(
    optionsExcluding(
      File(args.one('options')).readAsStringSync(),
      (report['notLoaded'] as List).cast<String>(),
    ),
  );
  return 0;
}
