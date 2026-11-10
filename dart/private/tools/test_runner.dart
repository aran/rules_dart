import 'dart:convert';
import 'dart:io';

import 'package:kernel_list/kernel_list.dart';
import 'package:runfiles/runfiles.dart';

import 'launcher_config.dart';

/// Runs a `dart_test`'s pre-compiled kernel with asserts enabled.
///
/// `dart_test` compiles the test at build time, so this launcher only resolves
/// files from runfiles and starts the VM — there is no package_config or source
/// co-location to do at runtime.
///
/// A test that depends on `package:test` runs under that package's own runner,
/// which this launcher adapts to Bazel's test protocol: `--test_filter` becomes
/// `--name`, sharding becomes `--total-shards`/`--shard-index`, the runner's
/// JSON report becomes the JUnit XML Bazel reads, and `package:test`'s own
/// 30-second default per case is replaced by Bazel's `TEST_TIMEOUT`, so that
/// Bazel's `size`/`timeout` is the limit. Any other test runs directly, and
/// refuses a filter or sharding it cannot honour rather than quietly running
/// everything.
///
/// The VM writes straight to this process's stdio rather than through it, so a
/// test that hangs until Bazel kills it still leaves what it printed in
/// test.log, and the launcher exits with the VM even if the test leaked a
/// process that holds those streams open.
Future<void> main(List<String> args) async {
  // Beside the executable rather than in the environment, so that a test run
  // as another target's `data` runs its own kernel (`launcher_config.dart`).
  final config = readLauncherConfig('dart_test');
  final r = Runfiles.create();
  final dart = r.rlocation(config['dart'] as String);
  final environment = childEnvironment(Platform.environment, r.environment);
  final scratch = _Scratch(Platform.environment['TEST_TMPDIR']);

  final String dill;
  try {
    dill = config['kernel_list'] == true
        ? stageKernelList(
            runfiles: r,
            program: config['dill'] as String,
            // The runner finds the suite by the test's path below its
            // precompiled directory.
            keep: switch (config['test_path']) {
              final String test => '$test.vm_test.vm.app.dill',
              _ => (config['dill'] as String).split('/').last,
            },
            codeAssetLibraries: (config['code_asset_libraries'] as List)
                .cast<String>(),
            into: scratch.directory('k'),
          )
        : r.rlocation(config['dill'] as String);
  } on KernelListException catch (e) {
    stderr.writeln('dart_test: $e');
    scratch.delete();
    exit(1);
  }

  final runnerKey = config['runner'] as String?;
  final int code;
  if (runnerKey == null) {
    code = await _runDirectly(dart, dill, args, environment);
  } else {
    code = await _runUnderRunner(
      dart: dart,
      dill: dill,
      runner: r.rlocation(runnerKey),
      testSource: r.rlocation(config['test_main'] as String),
      testPath: config['test_path'] as String,
      args: args,
      environment: environment,
      tmp: scratch.directory('dart_test.'),
    );
  }
  scratch.delete();
  exit(launcherExitCode(code));
}

/// Directories the launcher makes for one run: under `TEST_TMPDIR`, which
/// Bazel clears, or else under the system's temporary directory, where they
/// are removed when the test is done (`bazel run`).
class _Scratch {
  _Scratch(this._testTmpdir);

  final String? _testTmpdir;
  final _made = <Directory>[];

  Directory directory(String prefix) {
    final made = Directory(_testTmpdir ?? Directory.systemTemp.path)
        .createTempSync(prefix);
    _made.add(made);
    return made;
  }

  void delete() {
    if (_testTmpdir != null) return;
    for (final directory in _made) {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        // A process the test left running may still hold a file open. The
        // test's result stands; what is left behind is said.
        stderr.writeln('dart_test: could not remove ${directory.path}: $e');
      }
    }
  }
}

/// Writes the kernel list at runfiles path [program] again under [into],
/// naming each kernel where [runfiles] finds it, and returns the new list.
///
/// The list `dart_test` stores names its kernels by their paths from it in a
/// runfiles tree, which lead nowhere where runfiles are a manifest (Windows,
/// or `bazel run` resolving through one). The new list ends in [keep], the
/// tail of [program] its reader finds it by; the directories above that are
/// as many as [program] has but one character each, since Windows opens a
/// spawned isolate's file through a 260-character buffer. Each of
/// [codeAssetLibraries] is placed where its path from the stored list leads
/// from the new one: the VM resolves a code asset's `relative` path against
/// the list's directory.
String stageKernelList({
  required Runfiles runfiles,
  required String program,
  required String keep,
  required List<String> codeAssetLibraries,
  required Directory into,
}) {
  if (!program.endsWith('/$keep')) {
    throw ArgumentError.value(keep, 'keep', 'does not end $program');
  }
  final segments = program.split('/');
  final kept = keep.split('/');
  final above = segments.length - kept.length;
  final listSegments = [for (var i = 0; i < above; i++) '_', ...kept];
  String under(List<String> relative) =>
      _normalize([into.path, ...relative]).join(Platform.pathSeparator);

  final kernels = kernelsInRunfiles(runfiles, program);
  if (kernels.length == 1 && kernels.single == runfiles.rlocation(program)) {
    throw KernelListException('$program is not a kernel list');
  }
  final list = under(listSegments);
  // The VM opens a spawned isolate's file: URI through a MAX_PATH buffer
  // (`File::UriToPath`), and takes a list it cannot open for Dart source.
  if (Platform.isWindows && File(list).absolute.path.length >= 260) {
    throw KernelListException(
      'the kernel list ${File(list).absolute.path} is longer than the 259 '
      'characters the Dart VM opens on Windows; shorten --test_tmpdir',
    );
  }
  try {
    File(list).parent.createSync(recursive: true);
    writeKernelList(list, kernels);
  } on FileSystemException catch (e) {
    throw KernelListException('cannot write the kernel list $list', e);
  }
  final storedDirectory = segments.sublist(0, segments.length - 1);
  final listDirectory = listSegments.sublist(0, listSegments.length - 1);
  for (final library in codeAssetLibraries) {
    final placed = under([
      ...listDirectory,
      ..._relative(library.split('/'), storedDirectory),
    ]);
    try {
      final found = runfiles.rlocation(library);
      File(placed).parent.createSync(recursive: true);
      if (Platform.isWindows) {
        // A link to a file needs a privilege Windows grants few accounts.
        File(found).copySync(placed);
      } else {
        Link(placed).createSync(File(found).absolute.path);
      }
    } on Object catch (e) {
      // Not in runfiles (a StateError), or not placeable.
      if (e is! FileSystemException && e is! StateError) rethrow;
      throw KernelListException(
        'cannot place code asset $library beside the kernel list',
        e,
      );
    }
  }
  return list;
}

/// [path]'s segments from directory [from], both runfiles paths' segments.
List<String> _relative(List<String> path, List<String> from) {
  var common = 0;
  while (common < from.length &&
      common < path.length - 1 &&
      from[common] == path[common]) {
    common++;
  }
  return [
    for (var i = common; i < from.length; i++) '..',
    ...path.sublist(common),
  ];
}

/// [segments] with each `..` folding the segment before it.
List<String> _normalize(List<String> segments) {
  final out = <String>[];
  for (final s in segments) {
    if (s == '..' && out.isNotEmpty && out.last != '..') {
      out.removeLast();
    } else {
      out.add(s);
    }
  }
  return out;
}

/// The environment the test runs in: [parent]'s, which carries Bazel's test
/// and runfiles variables, without the `RULES_DART_` variables a launcher sets
/// for the program it starts, so that none reach a launcher the test itself
/// starts. [runfiles] adds the runfiles variables when the launcher found its
/// runfiles without them.
Map<String, String> childEnvironment(
  Map<String, String> parent,
  Map<String, String> runfiles,
) => {
  for (final MapEntry(:key, :value) in parent.entries)
    if (!key.startsWith('RULES_DART_')) key: value,
  ...runfiles,
};

/// The runner's default per-case timeout: Bazel's own for this test, which
/// Bazel always sets; `none` only when run outside Bazel.
String _suiteTimeout(Map<String, String> env) {
  final seconds = int.tryParse(env['TEST_TIMEOUT'] ?? '');
  return seconds == null ? 'none' : '${seconds}s';
}

/// The exit code `package:test`'s runner uses when no test ran.
const _noTestsRan = 79;

Future<int> _runDirectly(
  String dart,
  String dill,
  List<String> args,
  Map<String, String> environment,
) async {
  final env = Platform.environment;
  // A plain `main` has no notion of test cases, so there is nothing to filter
  // or split. Running every case anyway would report a filtered or sharded run
  // that never happened.
  if (env.containsKey('TESTBRIDGE_TEST_ONLY')) {
    stderr.writeln(
      'dart_test: --test_filter needs a test written with package:test; this '
      'one has a plain main() and cannot select cases.',
    );
    return 1;
  }
  if (env.containsKey('TEST_TOTAL_SHARDS')) {
    stderr.writeln(
      'dart_test: shard_count needs a test written with package:test; this '
      'one has a plain main() and cannot be split.',
    );
    return 1;
  }
  final vm = await Process.start(
    dart,
    ['--enable-asserts', dill, ...args],
    environment: environment,
    includeParentEnvironment: false,
    mode: ProcessStartMode.inheritStdio,
  );
  return vm.exitCode;
}

Future<int> _runUnderRunner({
  required String dart,
  required String dill,
  required String runner,
  required String testSource,
  required String testPath,
  required List<String> args,
  required Map<String, String> environment,
  required Directory tmp,
}) async {
  final env = Platform.environment;

  // The runner loads the precompiled suite from `<dir>/<path>.vm_test.vm.app.dill`
  // — which is where `dart_test` put the dill, so it is loaded in place — and
  // reads the test's source at `<path>` relative to its working directory for
  // its annotations. The suite runs as an isolate inside the runner, so the
  // runner's working directory is the test's: Bazel's contract makes that the
  // runfiles workspace root, where `data` is found by workspace-relative path.
  // Only where runfiles cannot hold the source at that relative path (Windows
  // has only a manifest) is the workspace's runfiles laid out in a scratch
  // directory from the manifest, to run in.
  final suffix = '/$testPath.vm_test.vm.app.dill';
  final normalized = dill.replaceAll(r'\', '/');
  if (!normalized.endsWith(suffix)) {
    stderr.writeln('dart_test: $dill is not laid out for $testPath');
    return 1;
  }
  final precompiled = dill.substring(0, dill.length - suffix.length);
  final inPlace = File(testPath).existsSync();
  if (!inPlace) {
    // The workspace's runfiles are laid out in the scratch directory, so `data`
    // is found by workspace-relative path as it is in a runfiles tree.
    final manifest = env['RUNFILES_MANIFEST_FILE'];
    final workspace = env['TEST_WORKSPACE'];
    if (manifest != null && workspace != null) {
      materializeWorkspace(
        manifest: File(manifest).readAsLinesSync(),
        workspace: workspace,
        into: tmp.path,
      );
    }
    final inScratch = File(_join(tmp.path, testPath));
    if (!inScratch.existsSync()) {
      File(testSource).copySync(inScratch.path);
    }
  }

  final filter = env['TESTBRIDGE_TEST_ONLY'];
  final totalShards = env['TEST_TOTAL_SHARDS'];
  final shardIndex = env['TEST_SHARD_INDEX'];
  final xmlOutput = env['XML_OUTPUT_FILE'];
  final shardStatus = env['TEST_SHARD_STATUS_FILE'];
  final report = _join(tmp.path, 'results.json');

  // Touched before the run, as Bazel asks: it is how a test runner says it
  // supports sharding at all.
  if (shardStatus != null) {
    File(shardStatus).writeAsStringSync('');
  }

  final vm = await Process.start(
    dart,
    [
      '--enable-asserts',
      runner,
      '--precompiled=$precompiled',
      '--reporter=expanded',
      // Bazel's timeout replaces `package:test`'s 30-second default. Not
      // `none`: in `package:test` a suite-level `none` also overrides the
      // timeout a test states on its own case, and that one is the author's.
      '--timeout=${_suiteTimeout(env)}',
      '--file-reporter=json:$report',
      if (filter != null && filter.isNotEmpty) ...['--name', filter],
      if (totalShards != null && shardIndex != null) ...[
        '--total-shards',
        totalShards,
        '--shard-index',
        shardIndex,
      ],
      testPath,
    ],
    workingDirectory: inPlace ? null : tmp.path,
    environment: {
      ...environment,
      // What the generated bootstrap hands the test's `main`.
      'RULES_DART_TEST_ARGS': jsonEncode(args),
      // The runner reads a per-user config (`~/.dart_test.yaml`, or
      // `%LOCALAPPDATA%\DartTest.yaml`) unless this names one. A path that
      // does not exist means none: a developer's own settings must not change
      // what a test does under Bazel, and Bazel's Windows test environment has
      // no LOCALAPPDATA for the runner to read at all.
      'DART_TEST_CONFIG': _join(tmp.path, 'no_global_config/DartTest.yaml'),
    },
    includeParentEnvironment: false,
    mode: ProcessStartMode.inheritStdio,
  );
  var code = await vm.exitCode;

  // A filter that selects nothing here, or a shard that drew no cases, is not
  // a failure: `bazel test //... --test_filter=x` has to pass every target the
  // filter does not touch.
  final selecting = filter != null || totalShards != null;
  if (code == _noTestsRan && selecting) {
    code = 0;
  }

  if (xmlOutput != null) {
    final reportFile = File(report);
    if (reportFile.existsSync()) {
      File(xmlOutput).writeAsStringSync(
        junitXml(reportFile.readAsLinesSync(), suiteName: testPath),
      );
    }
  }
  return code;
}

/// Lays out `workspace`'s runfiles under [into] from the lines of a runfiles
/// manifest, each `<runfiles path> <real path>`.
///
/// Where Bazel builds no runfiles tree (Windows by default) the manifest is all
/// there is, and a test's working directory would hold none of its `data`. A
/// real path that is a directory (a tree artifact is one entry) is copied whole.
void materializeWorkspace({
  required List<String> manifest,
  required String workspace,
  required String into,
}) {
  final prefix = '$workspace/';
  for (final line in manifest) {
    final space = line.indexOf(' ');
    if (space < 0 || !line.startsWith(prefix)) continue;
    final relative = line.substring(prefix.length, space);
    final real = line.substring(space + 1);
    final destination = _join(into, relative);
    if (Directory(real).existsSync()) {
      _copyDirectory(Directory(real), Directory(destination));
    } else if (File(real).existsSync()) {
      Directory(File(destination).parent.path).createSync(recursive: true);
      File(real).copySync(destination);
    }
  }
}

void _copyDirectory(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(from.path.length + 1);
    final target = _join(to.path, relative.replaceAll(r'\', '/'));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      Directory(File(target).parent.path).createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

/// Converts `package:test`'s JSON reporter output into JUnit XML, one
/// `testcase` per test the runner did not hide (it hides its own "loading"
/// pseudo-tests unless they fail).
String junitXml(List<String> lines, {required String suiteName}) {
  final names = <int, String>{};
  final starts = <int, int>{};
  final cases = <_Case>[];
  final byId = <int, _Case>{};
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, dynamic>) continue;
    final event = decoded;
    switch (event['type']) {
      case 'testStart':
        final test = event['test'] as Map<String, dynamic>;
        final id = test['id'] as int;
        names[id] = test['name'] as String;
        starts[id] = event['time'] as int;
      case 'error':
        final id = event['testID'] as int;
        (byId[id] ??= _Case(
          id,
        )).errors.add('${event['error']}\n${event['stackTrace']}');
      case 'print':
        final id = event['testID'] as int;
        (byId[id] ??= _Case(id)).output.writeln(event['message']);
      case 'testDone':
        final id = event['testID'] as int;
        final c = byId[id] ??= _Case(id);
        c
          ..hidden = event['hidden'] as bool? ?? false
          ..skipped = event['skipped'] as bool? ?? false
          ..result = event['result'] as String? ?? 'success'
          ..millis = (event['time'] as int) - (starts[id] ?? 0);
        cases.add(c);
    }
  }

  final shown = [
    for (final c in cases)
      if (!c.hidden || c.result != 'success') c,
  ];
  String seconds(int ms) => (ms / 1000).toStringAsFixed(3);
  final failures = shown.where((c) => c.result == 'failure').length;
  final errors = shown.where((c) => c.result == 'error').length;
  final skipped = shown.where((c) => c.skipped).length;
  final total = shown.fold<int>(0, (sum, c) => sum + c.millis);

  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<testsuites>')
    ..writeln(
      '  <testsuite name="${_attr(suiteName)}" tests="${shown.length}" '
      'failures="$failures" errors="$errors" skipped="$skipped" '
      'time="${seconds(total)}">',
    );
  for (final c in shown) {
    out.write(
      '    <testcase name="${_attr(names[c.id] ?? 'test ${c.id}')}" '
      'classname="${_attr(suiteName)}" time="${seconds(c.millis)}">',
    );
    if (c.skipped) {
      out.write('<skipped/>');
    } else if (c.result != 'success') {
      final tag = c.result == 'failure' ? 'failure' : 'error';
      final message = c.errors.isEmpty ? c.result : c.errors.first;
      out.write(
        '<$tag message="${_attr(message.split('\n').first)}">'
        '${_text(c.errors.join('\n'))}</$tag>',
      );
    }
    if (c.output.isNotEmpty) {
      out.write('<system-out>${_text(c.output.toString())}</system-out>');
    }
    out.writeln('</testcase>');
  }
  out
    ..writeln('  </testsuite>')
    ..writeln('</testsuites>');
  return out.toString();
}

class _Case {
  _Case(this.id);

  final int id;
  final List<String> errors = [];
  final StringBuffer output = StringBuffer();
  bool hidden = false;
  bool skipped = false;
  String result = 'success';
  int millis = 0;
}

String _text(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _attr(String s) => _text(s).replaceAll('"', '&quot;');

/// Joins a forward-slashed relative path onto [base], creating its parents.
String _join(String base, String relative) {
  final path = [base, ...relative.split('/')].join(Platform.pathSeparator);
  File(path).parent.createSync(recursive: true);
  return path;
}
