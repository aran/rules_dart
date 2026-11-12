// `bazel run @rules_dart//dart/unused_deps`: removes the deps the
// unused-dependency check finds from the BUILD files that state them.
//
//   bazel run @rules_dart//dart/unused_deps -- //app/...
//   bazel run @rules_dart//dart/unused_deps -- --dry-run //app:all
//
// The arguments after `--dry-run` are `bazel build`'s (`apply_args.dart`).
// The tool builds the check's reports (the `dart_unused_deps` output group)
// over the patterns, works out from `bazel query` which written labels they
// mean and which BUILD file entry states them (`unused_deps_fix.dart`), and
// has buildozer remove them from a copy of their BUILD files, which a real
// run writes back. `--dry-run` prints the buildozer commands instead. A dep
// buildozer cannot reach (one in a list variable or a comprehension) or that
// the entry must keep is reported with its place, and the tool exits 1.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'apply_args.dart';
import 'build_events.dart';
import 'unused_deps_fix.dart';

const _name = 'unused_deps';
const _usage =
    'usage: bazel run @rules_dart//dart/unused_deps -- [--dry-run] '
    '<bazel build arguments>';

Future<void> main(List<String> arguments) async {
  final buildozerArg = arguments.where((a) => a.startsWith('--buildozer='));
  if (buildozerArg.isEmpty) _fail('--buildozer= is required', 64);
  final buildozer = Runfiles.create().rlocation(
    buildozerArg.first.substring('--buildozer='.length),
  );
  final ApplyArgs args;
  try {
    args = parseArgs([
      for (final a in arguments)
        if (!a.startsWith('--buildozer=')) a,
    ]);
  } on UsageException catch (e) {
    _fail('${e.message}\n$_usage', 64);
  }

  // Set only under `bazel run`. Without them there is no source tree to
  // edit, and guessing one from the current directory could edit another.
  final env = Platform.environment;
  final workspace = env['BUILD_WORKSPACE_DIRECTORY'];
  final working = env['BUILD_WORKING_DIRECTORY'];
  if (workspace == null || working == null) {
    _fail('run with `bazel run @rules_dart//dart/unused_deps`', 1);
  }

  final scratch = Directory.systemTemp.createTempSync('dart_unused_deps.');
  try {
    exitCode = await _Fixer(
      args,
      scratch: scratch.path,
      working: working,
      workspace: workspace,
      buildozer: buildozer,
    ).run();
  } on _Failure catch (e) {
    stderr.writeln('$_name: ${e.message}');
    exitCode = e.code;
  } on FormatException catch (e) {
    stderr.writeln('$_name: ${e.message}');
    exitCode = 1;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

class _Failure implements Exception {
  _Failure(this.message, [this.code = 1]);
  final String message;
  final int code;
}

class _Fixer {
  _Fixer(
    this.args, {
    required this.scratch,
    required this.working,
    required this.workspace,
    required this.buildozer,
  });

  final ApplyArgs args;
  final String scratch;
  final String working;
  final String workspace;
  final String buildozer;
  var _files = 0;

  String _scratchFile(String name) =>
      '$scratch${Platform.pathSeparator}${_files++}.$name';

  Future<int> run() async {
    var reports = await _build();
    if (reports.isEmpty) {
      throw _Failure(
        'none of the targets checks its deps. Name Dart targets of this '
        'repository.',
      );
    }
    if (reports.every((r) => r.unused.isEmpty)) {
      stdout.writeln('$_name: no unused deps');
      return 0;
    }

    final mapping = (jsonDecode(
      await _bazel(['mod', 'dump_repo_mapping', '']),
    ) as Map).cast<String, String>();
    String canonical(String label) => canonicalLabel(label, mapping);
    final packages = {
      for (final r in reports)
        if (r.unused.isNotEmpty) r.label.substring(0, r.label.indexOf(':')),
    };
    final rules = await _rules(packages);

    // An entry's other targets judge its deps too: build their reports.
    final reported = {for (final r in reports) r.label};
    final entries = {
      for (final r in rules)
        if (reports.any(
          (p) => p.unused.isNotEmpty && p.label == canonical(r.label),
        ))
          r.entry,
    };
    final siblings = [
      for (final r in rules)
        if (entries.contains(r.entry) &&
            r.deps.isNotEmpty &&
            !reported.contains(canonical(r.label)))
          r.label,
    ];
    if (siblings.isNotEmpty) {
      // One the platform cannot build is skipped, and keeps its deps.
      reports = await _build(
        flags: ['--skip_incompatible_explicit_targets'],
        targets: siblings,
      );
    }

    final aliases = await _aliases({
      for (final r in rules)
        if (entries.contains(r.entry)) ...r.deps,
    }, canonical);
    // buildozer edits a copy of the BUILD files, one dep at a time, and its
    // exit codes say which removals it makes. A dry run stops there; a real
    // run writes the copies it edited back, so both report the same.
    final removals = findRemovals(
      reports: reports,
      rules: rules,
      aliases: aliases,
      canonical: canonical,
    );
    final mirror = await _Mirror.create(
      _scratchFile('mirror'),
      workspace: workspace,
      buildozer: buildozer,
      packages: {for (final e in removals.remove.keys) _package(e)},
    );
    final made = await editEach(removals, rules, mirror.remove);

    if (args.dryRun) {
      made.commands.forEach(stdout.writeln);
      return _reportKept(made.kept);
    }
    final left = <Kept>[];
    if (made.remove.isNotEmpty) {
      mirror.writeBack({for (final e in made.remove.keys) _package(e)});
      left.addAll(stillListed(made, await _rules(packages)));
    }
    final count = made.remove.values.fold(0, (n, deps) => n + deps.length);
    stdout.writeln(
      '$_name: removed $count deps from ${made.remove.length} BUILD file '
      'entries',
    );
    return _reportKept([...made.kept, ...left]);
  }

  int _reportKept(List<Kept> kept) {
    kept.forEach(stderr.writeln);
    return kept.isEmpty ? 0 : 1;
  }

  /// The reports the build makes of the caller's targets, and of [targets],
  /// with [flags] too.
  Future<List<UnusedReport>> _build({
    List<String> flags = const [],
    List<String> targets = const [],
  }) async {
    final events = _scratchFile('events.json');
    // From the directory `bazel run` was invoked in, so relative patterns
    // mean what they would on the user's own command line.
    final build = await Process.start(
      'bazel',
      [
        ...args.buildArgs(events).take(1),
        ...flags,
        ...args.buildArgs(events).skip(1),
        ...targets,
      ],
      workingDirectory: working,
      mode: ProcessStartMode.inheritStdio,
    );
    final built = await build.exitCode;
    if (built != 0) {
      throw _Failure('the build failed, so nothing was removed', built);
    }
    final (:configured, :files) = groupFiles(events, args.group);
    if (configured == 0) {
      // `bazel build` itself succeeds here, with "Found 0 targets".
      throw _Failure(
        'the build left out every target, so nothing was removed. A pattern '
        'can match nothing, and a named target is left out too when flags '
        'such as --build_tag_filters exclude it; pass the flags that build '
        'it: bazel run @rules_dart//dart/unused_deps -- --config=<config> '
        '<pattern>',
      );
    }
    return [
      for (final f in files) UnusedReport.parse(File(f).readAsStringSync()),
    ];
  }

  /// Every rule of [packages] (`@@//pkg`), as written.
  Future<List<QueriedRule>> _rules(Set<String> packages) async =>
      QueriedRule.parseAll(
        await _query([for (final p in packages) '${p.substring(2)}:all']),
      );

  /// Each alias [labels] lead to, by canonical label, to its `actual`s.
  Future<Map<String, List<String>>> _aliases(
    Set<String> labels,
    String Function(String) canonical,
  ) async {
    final aliases = <String, List<String>>{};
    final seen = <String>{};
    var pending = labels;
    while (pending.isNotEmpty) {
      seen.addAll(pending);
      final found = QueriedRule.parseAll(
        await _query(pending.toList(), kind: 'alias'),
      );
      pending = {};
      for (final alias in found) {
        aliases[canonical(alias.label)] = [
          for (final a in alias.actual) canonical(a),
        ];
        pending.addAll(alias.actual.where((a) => !seen.contains(a)));
      }
    }
    return aliases;
  }

  Future<String> _query(List<String> targets, {String? kind}) async {
    final file = _scratchFile('query');
    final set = 'set(${targets.join(' ')})';
    File(file).writeAsStringSync(kind == null ? set : 'kind("$kind", $set)');
    return _bazel([
      'query',
      '--output=streamed_jsonproto',
      '--query_file=$file',
    ]);
  }

  Future<String> _bazel(List<String> arguments) async {
    final result = await Process.run(
      'bazel',
      arguments,
      workingDirectory: workspace,
    );
    if (result.exitCode != 0) {
      throw _Failure(
        '`bazel ${arguments.join(' ')}` failed:\n${result.stderr}',
        result.exitCode,
      );
    }
    return result.stdout as String;
  }
}

/// The package of [label] (`//pkg:name`), as a workspace path.
String _package(String label) => label.substring(2, label.indexOf(':'));

/// A copy of some packages' BUILD files, which buildozer edits in place of
/// the workspace's. buildozer formats each file it edits, so the copies are
/// formatted first: then a command that removes nothing changes nothing,
/// and its exit code says so.
class _Mirror {
  _Mirror._(this.root, this.workspace, this.buildozer, this.files);

  static Future<_Mirror> create(
    String root, {
    required String workspace,
    required String buildozer,
    required Set<String> packages,
  }) async {
    final files = <String, String>{};
    for (final package in packages) {
      // The file Bazel and buildozer read, BUILD.bazel before BUILD.
      final dir = package.isEmpty ? workspace : '$workspace/$package';
      final name = ['BUILD.bazel', 'BUILD'].firstWhere(
        (n) => File('$dir/$n').existsSync(),
        orElse: () => throw _Failure('no BUILD file in $dir'),
      );
      final path = package.isEmpty ? name : '$package/$name';
      files[package] = path;
      File('$workspace/$path')
          .copySync((File('$root/$path')..createSync(recursive: true)).path);
    }
    // Where buildozer finds the root of the labels it is given.
    File('$root/MODULE.bazel').createSync(recursive: true);
    final mirror = _Mirror._(root, workspace, buildozer, files);
    if (packages.isNotEmpty) {
      await mirror._run(
        ['format', for (final p in packages) '//$p:__pkg__'],
        {0, 3},
      );
    }
    return mirror;
  }

  final String root;
  final String workspace;
  final String buildozer;

  /// Each package's BUILD file, by workspace path.
  final Map<String, String> files;

  /// Removes [dep] from [entry] in the copy, answering buildozer's exit code.
  Future<int> remove(String entry, String dep) =>
      _run(['remove deps $dep', entry], {0, 2, 3});

  /// Copies the BUILD files of [packages] back into the workspace.
  void writeBack(Set<String> packages) {
    for (final package in packages) {
      final path = files[package]!;
      File('$workspace/$path')
          .writeAsBytesSync(File('$root/$path').readAsBytesSync());
    }
  }

  Future<int> _run(List<String> arguments, Set<int> expected) async {
    final result = await Process.run(
      buildozer,
      arguments,
      workingDirectory: root,
    );
    if (!expected.contains(result.exitCode)) {
      throw _Failure(
        '`buildozer ${arguments.join(' ')}` exited ${result.exitCode}:\n'
        '${result.stdout}${result.stderr}',
      );
    }
    return result.exitCode;
  }
}

Never _fail(String message, int code) {
  stderr.writeln('$_name: $message');
  exit(code);
}
