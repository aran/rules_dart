import 'dart:convert';
import 'dart:io';

import 'package:kernel_list/kernel_list.dart';
import 'package:runfiles/runfiles.dart';

import 'launcher_config.dart';
import 'runner_snapshot.dart';

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
/// Bazel's `size`/`timeout` is the limit. Cases are selected by tag with the
/// target's `include_tags`/`exclude_tags` and the run's `DART_TEST_TAGS`/
/// `DART_TEST_EXCLUDE_TAGS` (`TagSelection`), and a run's
/// `DART_TEST_ORDERING_SEED` shuffles the cases. The runner reads no
/// `dart_test.yaml`: what it would set, the target says. Any other test runs
/// directly, and refuses a filter, a tag selection, an ordering seed or
/// sharding it cannot honour rather than quietly running everything. With
/// `--@rules_dart//dart:runner_snapshot`, the runner starts from an app-JIT
/// snapshot cached on the machine, which the first run to find none trains
/// (`runner_snapshot.dart`).
///
/// The VM writes straight to this process's stdio rather than through it, so a
/// test that hangs until Bazel kills it still leaves what it printed in
/// test.log, and the launcher exits with the VM even if the test leaked a
/// process that holds those streams open.
/// The package config every VM this launcher starts is given, an empty one:
/// without it the VM looks for one up from the program's directory, and
/// outside a sandbox finds the workspace's own `.dart_tool`, through the exec
/// root. A compiled program needs none, and what it would find depends on the
/// strategy that ran it and whether `dart pub get` ever ran in the workspace.
late final String _packagesOption;

Future<void> main(List<String> args) async {
  // Beside the executable rather than in the environment, so that a test run
  // as another target's `data` runs its own kernel (`launcher_config.dart`).
  final config = readLauncherConfig('dart_test');
  final r = Runfiles.create();
  final dart = r.rlocation(config['dart'] as String);
  _packagesOption = '--packages=${r.rlocation(config['packages'] as String)}';
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
            keep: config.containsKey('runner')
                ? '${config['test_path']}.vm_test.vm.app.dill'
                : (config['dill'] as String).split('/').last,
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

  final testPath = config['test_path'] as String;
  final String workingDirectory;
  try {
    workingDirectory = testWorkingDirectory(
      runfiles: r,
      directory: config['working_directory'] as String,
      testPath: testPath,
      layout: () => RunfilesLayout.read(r, config),
      scratch: () => scratch.directory('runfiles.'),
    );
  } on TestWorkingDirectoryException catch (e) {
    stderr.writeln('dart_test: $e');
    scratch.delete();
    exit(1);
  }

  final runnerKey = config['runner'] as String?;
  final tags = TagSelection.of(config, Platform.environment);
  final coverage = CoverageRun.of(
    config,
    r,
    Platform.environment,
    () => scratch.directory('c').path,
  );
  final int code;
  if (runnerKey == null) {
    code = await _runDirectly(
      dart,
      dill,
      args,
      environment,
      tags,
      coverage,
      workingDirectory,
    );
  } else {
    final snapshot = config['runner_snapshot'] as Map<String, dynamic>?;
    code = await _runUnderRunner(
      dart: dart,
      dill: dill,
      runner: r.rlocation(runnerKey),
      snapshotKey: snapshot == null
          ? null
          : () => RunnerSnapshotCache.keyOf(
              vm: snapshot['vm'] as String,
              digest: File(r.rlocation(snapshot['digest'] as String))
                  .readAsStringSync(),
            ),
      testPath: testPath,
      tags: tags,
      args: args,
      environment: environment,
      workingDirectory: workingDirectory,
      tmp: scratch.directory('dart_test.'),
      coverage: coverage,
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

/// Which cases run, by their `package:test` tags: the target's own selection
/// (`include_tags`/`exclude_tags`, from the launcher's config) and this run's
/// (`DART_TEST_TAGS`/`DART_TEST_EXCLUDE_TAGS`, from `--test_env`).
///
/// Each becomes a runner `--tags` or `--exclude-tags`, which combine as
/// `package:test` combines its configuration with its command line: a case
/// must match every include and no exclude. A run's value is passed as
/// `dart test --tags` takes it, commas included; empty means none.
class TagSelection {
  TagSelection({
    this.include = const [],
    this.exclude = const [],
    this.runInclude,
    this.runExclude,
  });

  factory TagSelection.of(
    Map<String, dynamic> config,
    Map<String, String> environment,
  ) {
    String? set(String name) => switch (environment[name]) {
      final String value when value.isNotEmpty => value,
      _ => null,
    };
    return TagSelection(
      include: (config['include_tags'] as List? ?? const []).cast<String>(),
      exclude: (config['exclude_tags'] as List? ?? const []).cast<String>(),
      runInclude: set('DART_TEST_TAGS'),
      runExclude: set('DART_TEST_EXCLUDE_TAGS'),
    );
  }

  /// The target's `include_tags` and `exclude_tags`.
  final List<String> include;
  final List<String> exclude;

  /// This run's `DART_TEST_TAGS` and `DART_TEST_EXCLUDE_TAGS`.
  final String? runInclude;
  final String? runExclude;

  bool get fixed => include.isNotEmpty || exclude.isNotEmpty;
  bool get perRun => runInclude != null || runExclude != null;

  /// The runner's arguments for this selection.
  List<String> get arguments => [
    for (final selector in [...include, ?runInclude]) '--tags=$selector',
    for (final selector in [...exclude, ?runExclude])
      '--exclude-tags=$selector',
  ];

  /// This run's selection, as it was set.
  String describePerRun() => [
    if (runInclude != null) 'DART_TEST_TAGS=$runInclude',
    if (runExclude != null) 'DART_TEST_EXCLUDE_TAGS=$runExclude',
  ].join(' and ');

  /// The target's selection, as its attributes say it.
  String describeFixed() => [
    if (include.isNotEmpty) 'include_tags = ${jsonEncode(include)}',
    if (exclude.isNotEmpty) 'exclude_tags = ${jsonEncode(exclude)}',
  ].join(' and ');
}

/// This run's `DART_TEST_ORDERING_SEED` (from `--test_env`), which the
/// runner takes as `--test-randomize-ordering-seed`: an unsigned 32-bit
/// integer, or `random` for one the runner picks and prints. Empty means none.
String? orderingSeed(Map<String, String> environment) =>
    switch (environment['DART_TEST_ORDERING_SEED']) {
      final String value when value.isNotEmpty => value,
      _ => null,
    };

/// The tags `package:test`'s runner names in its [output] as used by the
/// suite but not declared: with no tags selected and no configuration read,
/// every tag the suite, its groups and its cases use.
///
/// The runner reports a suite's tags nowhere else: its JSON reporter leaves
/// them out, and a case a selection drops is not reported at all.
Set<String> usedTags(String output) => {
  for (final match in RegExp(
    r'^  (\S+) was used in',
    multiLine: true,
  ).allMatches(output))
    match[1]!,
};

Future<int> _runDirectly(
  String dart,
  String dill,
  List<String> args,
  Map<String, String> environment,
  TagSelection tags,
  CoverageRun? coverage,
  String workingDirectory,
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
  if (tags.perRun) {
    stderr.writeln(
      'dart_test: ${tags.describePerRun()} needs a test written with '
      'package:test; this one has a plain main() and cannot select cases.',
    );
    return 1;
  }
  if (orderingSeed(env) case final seed?) {
    stderr.writeln(
      'dart_test: DART_TEST_ORDERING_SEED=$seed needs a test written with '
      'package:test; this one has a plain main() and cannot shuffle cases.',
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
  if (coverage != null) {
    return coverage.runDirectly(
      dart,
      dill,
      args,
      environment,
      workingDirectory,
    );
  }
  final vm = await Process.start(
    dart,
    [_packagesOption, '--enable-asserts', dill, ...args],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
    mode: ProcessStartMode.inheritStdio,
  );
  return vm.exitCode;
}

/// A run under `bazel coverage`: the test's line coverage, collected by the
/// tools `dart_test` ships under coverage, lands in `COVERAGE_DIR` as an
/// LCOV tracefile, which Bazel's coverage runner merges into the test's
/// `coverage.dat` (`coverage_collector.dart`, `coverage_converter.dart`).
class CoverageRun {
  CoverageRun._(
    this.collector,
    this.converter,
    this.sources,
    this.directory,
    this._scratch,
  );

  /// The run's coverage, when `dart_test` was built for coverage and Bazel
  /// collects it: `bazel run` of a coverage build collects none.
  static CoverageRun? of(
    Map<String, dynamic> config,
    Runfiles runfiles,
    Map<String, String> environment,
    String Function() scratch,
  ) {
    final coverage = config['coverage'] as Map<String, dynamic>?;
    final directory = environment['COVERAGE_DIR'];
    if (coverage == null || directory == null) return null;
    return CoverageRun._(
      runfiles.rlocation(coverage['collector'] as String),
      runfiles.rlocation(coverage['converter'] as String),
      runfiles.rlocation(coverage['sources'] as String),
      directory,
      scratch(),
    );
  }

  /// `coverage_collector`, which runs a plain-`main()` test.
  final String collector;

  /// `coverage_converter`, which converts what `package:test`'s runner wrote.
  final String converter;
  final String sources;

  /// `COVERAGE_DIR`, where the tracefile goes: the coverage runner merges
  /// every `*.dat` in it.
  final String directory;

  /// Where the run's other files go, out of `COVERAGE_DIR`.
  final String _scratch;

  String get _output => '$directory${Platform.pathSeparator}dart_test.dat';

  /// Where `package:test`'s runner writes each suite's coverage.
  String get runnerDirectory => '$_scratch${Platform.pathSeparator}runner';

  /// Runs a plain-`main()` test through the collector, with the VM service
  /// on and each isolate pausing as it exits until the collector has read
  /// its coverage.
  Future<int> runDirectly(
    String dart,
    String dill,
    List<String> args,
    Map<String, String> environment,
    String workingDirectory,
  ) async {
    final info = '$_scratch${Platform.pathSeparator}vm_service.json';
    final collecting = await Process.start(
      collector,
      [
        '--service-info=$info',
        '--sources=$sources',
        '--output=$_output',
        '--',
        dart,
        _packagesOption,
        '--enable-vm-service=0',
        '--pause-isolates-on-exit',
        '--no-dds',
        '--write-service-info=${Uri.file(info)}',
        '--enable-asserts',
        dill,
        ...args,
      ],
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      mode: ProcessStartMode.inheritStdio,
    );
    return collecting.exitCode;
  }

  /// Converts what `package:test`'s runner collected into the tracefile.
  Future<int> convertRunnerCoverage(Map<String, String> environment) async {
    final collecting = await Process.start(
      converter,
      ['--hitmaps=$runnerDirectory', '--sources=$sources', '--output=$_output'],
      environment: environment,
      includeParentEnvironment: false,
      mode: ProcessStartMode.inheritStdio,
    );
    return collecting.exitCode;
  }
}

Future<int> _runUnderRunner({
  required String dart,
  required String dill,
  required String runner,
  required String Function()? snapshotKey,
  required String testPath,
  required TagSelection tags,
  required List<String> args,
  required Map<String, String> environment,
  required String workingDirectory,
  required Directory tmp,
  required CoverageRun? coverage,
}) async {
  final env = Platform.environment;

  // The runner loads the precompiled suite from `<dir>/<path>.vm_test.vm.app.dill`
  // — which is where `dart_test` put the dill, so it is loaded in place — and
  // reads the test's source at `<path>` from its working directory, the
  // test's package root, for its annotations. The suite runs as an isolate
  // inside the runner, so the runner's working directory is the test's.
  final suffix = '/$testPath.vm_test.vm.app.dill';
  final normalized = dill.replaceAll(r'\', '/');
  if (!normalized.endsWith(suffix)) {
    stderr.writeln('dart_test: $dill is not laid out for $testPath');
    return 1;
  }
  final precompiled = dill.substring(0, dill.length - suffix.length);

  final filter = env['TESTBRIDGE_TEST_ONLY'];
  final seed = orderingSeed(env);
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

  // The runner's own arguments, after the program it starts from.
  final timeout = '--timeout=${_suiteTimeout(env)}';
  // The runner reads `dart_test.yaml` from its working directory, the
  // package root, where a package's own file is if a target's `data` happens
  // to hold it. A path that does not exist means none: what the file would
  // set, the target says (README, Tests).
  final noConfiguration =
      '--configuration=${_join(tmp.path, 'no_project_config/dart_test.yaml')}';
  final runnerArguments = [
    '--precompiled=$precompiled',
    '--reporter=expanded',
    noConfiguration,
    // Bazel's timeout replaces `package:test`'s 30-second default. Not
    // `none`: in `package:test` a suite-level `none` also overrides the
    // timeout a test states on its own case, and that one is the author's.
    timeout,
    '--file-reporter=json:$report',
    if (filter != null && filter.isNotEmpty) ...['--name', filter],
    ...tags.arguments,
    // The runner prints the seed it shuffles with, `random`'s included, so
    // test.log says how to repeat the order.
    if (seed != null) '--test-randomize-ordering-seed=$seed',
    if (totalShards != null && shardIndex != null) ...[
      '--total-shards',
      totalShards,
      '--shard-index',
      shardIndex,
    ],
    // The runner collects each suite's coverage itself, before it ends the
    // suite's isolate.
    if (coverage != null) '--coverage=${coverage.runnerDirectory}',
    testPath,
  ];
  final runEnvironment = {
    ...environment,
    // What the generated bootstrap hands the test's `main`.
    'RULES_DART_TEST_ARGS': jsonEncode(args),
    // The runner reads a per-user config (`~/.dart_test.yaml`, or
    // `%LOCALAPPDATA%\DartTest.yaml`) unless this names one. A path that
    // does not exist means none: a developer's own settings must not change
    // what a test does under Bazel, and Bazel's Windows test environment has
    // no LOCALAPPDATA for the runner to read at all.
    'DART_TEST_CONFIG': _join(tmp.path, 'no_global_config/DartTest.yaml'),
  };

  // With the cache, the runner starts from its snapshot, or from its kernel
  // with a snapshot trained after the test (`runner_snapshot.dart`).
  RunnerSnapshotCache? cache;
  RunnerSnapshotPlan? plan;
  if (snapshotKey != null) {
    try {
      final String key;
      try {
        key = snapshotKey();
      } on Object catch (e) {
        // Not in runfiles (a StateError), or unreadable.
        if (e is! FileSystemException && e is! StateError) rethrow;
        throw RunnerSnapshotException('cannot read the runner digest: $e');
      }
      cache = RunnerSnapshotCache.open(key: key, environment: env);
      plan = cache.plan();
    } on RunnerSnapshotException catch (e) {
      stderr.writeln(e);
      return 1;
    } on FileSystemException catch (e) {
      stderr.writeln(RunnerSnapshotException('the cache failed: $e'));
      return 1;
    }
  }

  final Process vm;
  try {
    vm = await Process.start(
      dart,
      [
        _packagesOption,
        '--enable-asserts',
        if (plan is StartFromSnapshot) plan.snapshot.path else runner,
        ...runnerArguments,
      ],
      workingDirectory: workingDirectory,
      environment: runEnvironment,
      includeParentEnvironment: false,
      mode: ProcessStartMode.inheritStdio,
    );
  } on Object {
    if (plan is TrainSnapshot) plan.abandon();
    rethrow;
  }
  var code = await vm.exitCode;

  // The runner writes its report from the start, so a run that failed without
  // one never started the runner: the VM refused the snapshot.
  if (plan is StartFromSnapshot && code != 0 && !File(report).existsSync()) {
    stderr.writeln(cache!.refused(plan.snapshot, code));
    return 1;
  }

  // A filter or a run's tags that select nothing here, or a shard that drew
  // no cases, is not a failure: `bazel test //... --test_filter=x` has to pass
  // every target the filter does not touch. The target's own tags selecting
  // nothing are: it would never run a case.
  if (code == _noTestsRan) {
    if (tags.perRun && totalShards == null) {
      code = await _noteUnselected(
        dart: dart,
        program: plan is StartFromSnapshot ? plan.snapshot.path : runner,
        arguments: [
          '--precompiled=$precompiled',
          '--reporter=expanded',
          '--no-color',
          noConfiguration,
          '--name',
          '(?!)',
          testPath,
        ],
        workingDirectory: workingDirectory,
        environment: runEnvironment,
        testPath: testPath,
        tags: tags,
      );
    } else if (filter != null || totalShards != null || tags.perRun) {
      code = 0;
    } else if (tags.fixed) {
      stderr.writeln(
        'dart_test: ${tags.describeFixed()} select no case of $testPath.',
      );
    }
  }

  if (coverage != null && code == 0) {
    if (await coverage.convertRunnerCoverage(environment) != 0) {
      stderr.writeln('dart_test: collecting coverage failed');
      code = 1;
    }
  }

  if (xmlOutput != null) {
    final reportFile = File(report);
    if (reportFile.existsSync()) {
      File(xmlOutput).writeAsStringSync(
        junitXml(reportFile.readAsLinesSync(), suiteName: testPath),
      );
    }
  }

  // The test's result is settled; the training is a run of its own on the
  // same suite with a filter no case matches, so that what the test does
  // cannot stop the VM writing the snapshot, nor the training change the
  // result.
  if (plan is TrainSnapshot) {
    try {
      await plan.train(
        dart: dart,
        vmOptions: [_packagesOption],
        runnerArguments: [
          runner,
          '--precompiled=$precompiled',
          '--reporter=expanded',
          noConfiguration,
          timeout,
          '--name',
          '(?!)',
          testPath,
        ],
        workingDirectory: workingDirectory,
        environment: runEnvironment,
      );
    } on RunnerSnapshotException catch (e) {
      stderr.writeln(e);
      if (code == 0) code = 1;
    } on FileSystemException catch (e) {
      stderr.writeln(RunnerSnapshotException('training failed: $e'));
      if (code == 0) code = 1;
    }
  }
  return code;
}

/// Says on stderr that this run's tags select no case of [testPath], and which
/// tags it uses, so that a run across many targets passes those whose cases
/// have none of them. Returns the test's exit code: 0, or 1 when the suite
/// could not be loaded again to find its tags.
///
/// The tags come from a run of the runner like the snapshot's training: no
/// case and no tags selected, so that it names every tag the suite uses.
Future<int> _noteUnselected({
  required String dart,
  required String program,
  required List<String> arguments,
  required String? workingDirectory,
  required Map<String, String> environment,
  required String testPath,
  required TagSelection tags,
}) async {
  final listing = await Process.run(
    dart,
    [_packagesOption, program, ...arguments],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
  );
  if (listing.exitCode != _noTestsRan) {
    stderr
      ..writeln(
        'dart_test: ${tags.describePerRun()} selects no case of $testPath, '
        'and loading it again to list its tags exited ${listing.exitCode}:',
      )
      ..write(listing.stdout)
      ..write(listing.stderr);
    return 1;
  }
  final used = usedTags('${listing.stdout}').toList()..sort();
  stderr.writeln(
    'dart_test: ${tags.describePerRun()} selects no case of $testPath, '
    'which passes, as a run\'s selection that touches no case does. '
    '${used.isEmpty ? 'It uses no tags.' : 'Its tags: ${used.join(', ')}.'}',
  );
  return 0;
}

/// Why a test has no directory to run in.
class TestWorkingDirectoryException implements Exception {
  TestWorkingDirectoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The directory a test runs in: runfiles path [directory], its package root,
/// which holds the test file at [testPath].
///
/// That is the directory in [runfiles]' tree. Where there is no tree holding
/// it (Windows by default, or `--noenable_runfiles`), the manifest is all
/// there is, and the runfiles the test brings ([layout]) are laid out from it
/// under a directory [scratch] makes, as a tree holds them, so that the test
/// finds what it reads at the same paths from where it runs.
String testWorkingDirectory({
  required Runfiles runfiles,
  required String directory,
  required String testPath,
  required RunfilesLayout Function() layout,
  required Directory Function() scratch,
}) {
  String under(String base, String relative) =>
      [base, ...relative.split('/')].join(Platform.pathSeparator);
  final tree = runfiles.environment['RUNFILES_DIR'];
  if (tree != null) {
    final inTree = under(tree, directory);
    if (File(under(inTree, testPath)).existsSync()) return inTree;
  }
  final manifest = runfiles.environment['RUNFILES_MANIFEST_FILE'];
  if (manifest == null) {
    throw TestWorkingDirectoryException(
      'the runfiles tree ${tree ?? '(none)'} does not hold $directory/'
      '$testPath, and there is no runfiles manifest to lay it out from',
    );
  }
  final RunfilesLayout laid;
  try {
    laid = layout();
  } on FileSystemException catch (e) {
    throw TestWorkingDirectoryException(
      'cannot read what to lay out from the runfiles manifest $manifest: $e',
    );
  }
  final into = scratch().path;
  _materialize(
    manifest: File(manifest).readAsLinesSync(),
    layout: laid,
    into: into,
  );
  final laidOut = under(into, directory);
  if (!File(under(laidOut, testPath)).existsSync()) {
    throw TestWorkingDirectoryException(
      'the runfiles manifest $manifest does not list $directory/$testPath',
    );
  }
  return laidOut;
}

/// Which runfiles a test's working directory holds where there is no
/// runfiles tree: those the test itself brings, its source, its `data` and
/// its libraries' resources and `data`, which `dart_test` lists beside the
/// launcher. Not the launcher's own (the VM, the kernels, the runner), which
/// it finds through the manifest, nor what the manifest lists for another
/// test that runs this one as its `data`, nor the Dart SDK ([sdk]), which a
/// test that brings it (`@rules_dart//dart` in `data`) finds through the
/// manifest as the launcher finds the VM.
class RunfilesLayout {
  RunfilesLayout(this.laidOut, {this.sdk = const {}});

  static RunfilesLayout read(Runfiles runfiles, Map<String, dynamic> config) {
    Set<String> list(String key) => runfilesPaths(
      File(runfiles.rlocation(config[key] as String)).readAsLinesSync(),
      workspace: config['workspace'] as String,
    );
    return RunfilesLayout(list('laid_out'), sdk: list('sdk_files'));
  }

  final Set<String> laidOut;
  final Set<String> sdk;

  /// Whether the runfile at runfiles path [path] is laid out.
  bool holds(String path) => laidOut.contains(path) && !sdk.contains(path);
}

/// The runfiles paths of the `short_path`s in [lines]: one in the main
/// repository is below [workspace], one in another repository starts `../`.
Set<String> runfilesPaths(List<String> lines, {required String workspace}) => {
  for (final line in lines)
    if (line.isNotEmpty)
      line.startsWith('../') ? line.substring(3) : '$workspace/$line',
};

/// Lays out the runfiles [layout] holds under [into] from the lines of a
/// runfiles manifest, each `<runfiles path> <real path>`, at their runfiles
/// paths, as a runfiles tree holds them.
///
/// A real path that is a directory (a tree artifact is one entry) is copied
/// whole. A symlink, as a repository's files can hold, is copied as what it
/// points at, as a runfiles tree reads it.
void _materialize({
  required List<String> manifest,
  required RunfilesLayout layout,
  required String into,
}) {
  for (final line in manifest) {
    final space = line.indexOf(' ');
    if (space < 0) continue;
    final relative = line.substring(0, space);
    if (!layout.holds(relative)) continue;
    final real = line.substring(space + 1);
    final destination = _join(into, relative);
    if (Directory(real).existsSync()) {
      _copyDirectory(Directory(real), Directory(destination));
    } else if (File(real).existsSync()) {
      _copyFile(real, destination);
    }
  }
}

void _copyDirectory(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: true)) {
    final relative = entity.path.substring(from.path.length + 1);
    final target = _join(to.path, relative.replaceAll(r'\', '/'));
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      _copyFile(entity.path, target);
    }
  }
}

/// Copies the file at [from], or the file a symlink there points at, to [to].
///
/// On Windows `File.copySync` refuses a symlink, as if nothing were there.
void _copyFile(String from, String to) {
  Directory(File(to).parent.path).createSync(recursive: true);
  File(File(from).resolveSymbolicLinksSync()).copySync(to);
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
