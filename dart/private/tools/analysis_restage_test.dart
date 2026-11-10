import 'dart:io';
import 'dart:math';

import 'package:bazel_worker/driver.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The analysis worker's guard: a sequence of projects staged, restaged and
/// edited at the same few paths, each analyzed by one long-lived worker and
/// by a fresh `dart analyze`, which must agree on every one.
///
/// A worker keeps its analysis server across requests and resets it for each
/// (`AnalysisServer.reanalyze`). What the server keeps across a reset is keyed
/// by content; this is what shows that nothing a request staged leaks into a
/// later one, whatever changed between them and however.
///
/// Arguments are the runfiles paths of `analyze_runner`, `analysis_host.dart`
/// and a copy of the SDK's `analyze` file set.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  // A copy of the SDK's `analyze` file set: the files the actions get.
  final dart =
      '${runfiles.rlocation(args[2])}/bin/dart'
      '${Platform.isWindows ? '.exe' : ''}';
  final runner = runfiles.rlocation(args[0]);
  final host = runfiles.rlocation(args[1]);

  late Directory root;
  late BazelWorkerDriver worker;
  var requests = 0;
  setUpAll(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('analysis_restage_test')
          .resolveSymbolicLinksSync(),
    );
    final execroot = Directory('${root.path}/output_base/execroot/_main')
      ..createSync(recursive: true);
    worker = BazelWorkerDriver(
      () => Process.start(runner, [
        '--host',
        host,
        '--persistent_worker',
      ], workingDirectory: execroot.path),
      maxWorkers: 1,
    );
  });
  tearDownAll(() async {
    await worker.terminateWorkers();
    root.deleteSync(recursive: true);
  });

  /// Analyzes [dir] through the worker and with a fresh `dart analyze` (the
  /// runner without a host), and expects the same exit code and report.
  Future<void> check(String dir) async {
    final n = ++requests;
    List<String> analyze(String stamp) => [
      '--dart',
      dart,
      '--project',
      dir,
      '--stamp',
      stamp,
      '--fatal-infos',
    ];
    final (viaWorker, fresh) = await (
      worker.doWork(WorkRequest(arguments: analyze('${root.path}/stamps/w$n'))),
      Process.run(runner, analyze('${root.path}/stamps/f$n')),
    ).wait;
    // `dart analyze` says what it is analyzing; the worker does not.
    String report(String out) => out
        .split('\n')
        .where((l) => !l.startsWith('Analyzing '))
        .join('\n')
        .trim();
    expect(
      (exitCode: viaWorker.exitCode, report: report(viaWorker.output)),
      (exitCode: fresh.exitCode, report: report(fresh.stderr as String)),
    );
  }

  setUp(() => Directory('${root.path}/stamps').createSync(recursive: true));

  final stage = _Stager(() => root.path);

  test('directed re-stagings', () async {
    final p = '${root.path}/p';
    final q = '${root.path}/q';

    // An `include:` from a package whose file changes in place.
    const inc = 'include: package:opts/opts.yaml\n$_excludeDeps';
    stage.tree(p, {..._base(options: inc), 'lib/d.dart': 'f() => "x";\n'});
    await check(p);
    _put(
      p,
      'deps/opts/lib/opts.yaml',
      'linter:\n  rules:\n    - prefer_single_quotes\n'
          '    - always_declare_return_types\n',
    );
    await check(p);
    _put(p, 'deps/opts/lib/opts.yaml', _noLints, keepStamp: true);
    await check(p);
    _put(
      p,
      'deps/opts2/lib/opts.yaml',
      'linter:\n  rules:\n    - prefer_single_quotes\n',
    );
    _put(
      p,
      '.dart_tool/package_config.json',
      _config('3.10', optRoot: '../deps/opts2'),
    );
    await check(p);

    // The pubspec and the language version.
    stage.tree(p, {
      ..._base(lang: '3.6'),
      'lib/n.dart': 'List<int> f(int? x) => [?x];\n',
    });
    await check(p);
    _put(p, '.dart_tool/package_config.json', _config('3.10'));
    await check(p);
    _put(p, 'lib/n.dart', '// @dart=3.6\nList<int> f(int? x) => [?x];\n');
    await check(p);
    _put(
      p,
      'pubspec.yaml',
      '$_pubspec'
          'dependencies:\n  dep: any\n  missing_pkg: ^1.0.0\n',
    );
    await check(p);
    _put(p, 'pubspec.yaml', 'name: Probe Bad\nenvironment:\n  sdk: ^3.6.0\n');
    await check(p);
    _put(p, 'pubspec.yaml', _pubspec);
    await check(p);

    // Two projects taking turns at one path.
    final one = {..._base(), 'lib/b.dart': 'int b() => "";\n'};
    final two = {
      ..._base(
        options:
            '$_excludeDeps\nlinter:\n  rules:\n    - prefer_single_quotes\n',
      ),
      'lib/c.dart': 'String c() => "q";\n',
    };
    for (var i = 0; i < 3; i++) {
      stage.tree(p, one);
      await check(p);
      stage.tree(p, two);
      await check(p);
    }

    // The same size and modification time, other content.
    stage.tree(p, {..._base(), 'lib/b.dart': 'int b() => 22;\n'});
    await check(p);
    _put(p, 'lib/b.dart', 'int b() => "";\n', keepStamp: true);
    await check(p);

    // Symlinks, as a sandbox stages inputs, whose targets change.
    stage.tree(p, {
      ..._base(),
      'lib/b.dart': 'int b() => 2;\n',
    }, symlinks: true);
    await check(p);
    File(Link('$p/lib/b.dart').targetSync())
        .writeAsStringSync('int b() => "";\n');
    await check(p);
    for (final (dir, body) in [
      ('depA', 'int depValue() => 1;\n'),
      ('depB', 'String depValue() => "";\n'),
    ]) {
      File('${root.path}/$dir/lib/dep.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }
    stage.tree(q, _base()..remove('deps/dep/lib/dep.dart'));
    Link('$q/deps/dep').createSync('${root.path}/depA');
    await check(q);
    Link('$q/deps/dep').updateSync('${root.path}/depB');
    await check(q);
    Link('$q/deps/dep').updateSync('${root.path}/depA');
    await check(q);

    // A burst of edits to a root the server watched, just before a request.
    stage.tree(p, {..._base(), 'lib/b.dart': 'int b() => 2;\n'});
    await check(p);
    for (var i = 0; i < 50; i++) {
      _put(p, 'lib/b.dart', i.isEven ? 'int b() => "";\n' : 'int b() => 3;\n');
      _put(p, 'lib/x$i.dart', 'int x$i() => $i;\n');
    }
    _put(p, 'lib/b.dart', 'int b() => 4;\n');
    await check(p);
    stage.tree(p, {..._base(), 'lib/b.dart': 'int b() => "";\n'});
    await check(p);

    // The previous root removed and rewritten during the next request.
    stage.tree(q, {..._base(), 'lib/b.dart': 'int b() => 2;\n'});
    final checkQ = check(q);
    Directory(p).deleteSync(recursive: true);
    stage.tree(p, {..._base(), 'lib/z.dart': 'void z() { int u = ""; }\n'});
    await checkQ;
    await check(p);
  });

  for (final seed in [1, 2]) {
    test('random re-stagings, seed $seed', () async {
      final rng = Random(seed);
      T pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];
      final paths = ['${root.path}/r1', '${root.path}/r2'];
      final state = <String, Map<String, String>>{};
      for (var i = 0; i < _randomSteps; i++) {
        final dir = pick(paths);
        final files = Map.of(state[dir] ?? _base());
        for (var k = 0, n = 1 + rng.nextInt(3); k < n; k++) {
          switch (rng.nextInt(6)) {
            case 0:
              files['lib/b.dart'] = pick(_bodies);
            case 1:
              files['deps/dep/lib/dep.dart'] = pick(_deps);
            case 2:
              files['analysis_options.yaml'] = pick(_options);
            case 3:
              files['deps/opts/lib/opts.yaml'] = pick(_included);
            case 4:
              files['.dart_tool/package_config.json'] = _config(
                pick(['3.6', '3.10']),
              );
            case 5:
              if (files.remove('lib/c.dart') == null) {
                files['lib/c.dart'] = 'int c() => "c";\n';
              }
          }
        }
        final how = rng.nextInt(3);
        final old = state[dir];
        if (how == 0 || old == null) {
          stage.tree(dir, files, symlinks: rng.nextBool());
        } else {
          // Edited in place, half of these keeping modification times.
          for (final rel in old.keys.where((k) => !files.containsKey(k))) {
            File('$dir/$rel').deleteSync();
          }
          for (final MapEntry(:key, :value) in files.entries) {
            if (old[key] != value) _put(dir, key, value, keepStamp: how == 2);
          }
        }
        state[dir] = files;
        await check(dir);
      }
    });
  }
}

const _randomSteps = 40;

const _pubspec = 'name: probe\nenvironment:\n  sdk: ^3.6.0\n';
const _excludeDeps = 'analyzer:\n  exclude:\n    - deps/**\n';
const _noLints = 'linter:\n  rules: []\n';

const _bodies = [
  'int b() => 2;\n',
  'int b() => "";\n',
  'void b() { var unused = 1; }\n',
  'b() => "dq";\n',
  "import 'missing.dart';\nint b() => 1;\n",
  "import 'package:dep/dep.dart';\nint b() => depValue();\n",
  'List<int> b(int? x) => [?x];\n',
];
const _deps = ['int depValue() => 1;\n', 'String depValue() => "";\n'];
const _options = [
  _excludeDeps,
  '$_excludeDeps\nlinter:\n  rules:\n    - prefer_single_quotes\n'
      '    - always_declare_return_types\n',
  'include: package:opts/opts.yaml\n$_excludeDeps',
  '$_excludeDeps    - lib/b.dart\n',
];
const _included = [_noLints, 'linter:\n  rules:\n    - prefer_single_quotes\n'];

String _config(
  String lang, {
  String depRoot = '../deps/dep',
  String optRoot = '../deps/opts',
}) =>
    '{"configVersion":2,"packages":['
    '{"name":"probe","rootUri":"../","packageUri":"lib/",'
    '"languageVersion":"$lang"},'
    '{"name":"dep","rootUri":"$depRoot","packageUri":"lib/",'
    '"languageVersion":"3.10"},'
    '{"name":"opts","rootUri":"$optRoot","packageUri":"lib/",'
    '"languageVersion":"3.10"}'
    ']}\n';

Map<String, String> _base({
  String lang = '3.10',
  String options = _excludeDeps,
}) => {
  'pubspec.yaml': _pubspec,
  '.dart_tool/package_config.json': _config(lang),
  'analysis_options.yaml': options,
  'deps/dep/lib/dep.dart': 'int depValue() => 1;\n',
  'deps/opts/lib/opts.yaml': _noLints,
  'lib/a.dart': "import 'package:dep/dep.dart';\n\nint a() => depValue();\n",
};

/// Writes [content] to [rel] under [dir], replacing a symlink there, keeping
/// the file's modification time if [keepStamp].
void _put(String dir, String rel, String content, {bool keepStamp = false}) {
  final file = File('$dir/$rel');
  file.parent.createSync(recursive: true);
  final stamp = keepStamp && file.existsSync() ? file.lastModifiedSync() : null;
  if (FileSystemEntity.isLinkSync(file.path)) Link(file.path).deleteSync();
  file.writeAsStringSync(content);
  if (stamp != null) file.setLastModifiedSync(stamp);
}

class _Stager {
  _Stager(this._root);

  final String Function() _root;
  var _stores = 0;

  /// Replaces [dir] with exactly [files]: plain files, or symlinks into a
  /// fresh store, as a sandbox stages them.
  void tree(String dir, Map<String, String> files, {bool symlinks = false}) {
    final d = Directory(dir);
    if (d.existsSync()) d.deleteSync(recursive: true);
    final store = '${_root()}/store${++_stores}';
    for (final MapEntry(:key, :value) in files.entries) {
      if (symlinks) {
        final real = File('$store/$key')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(value);
        Link('$dir/$key')
          ..parent.createSync(recursive: true)
          ..createSync(real.path);
      } else {
        _put(dir, key, value);
      }
    }
  }
}
