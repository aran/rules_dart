/// Measures how long rules_dart makes its users wait, on one machine, so a
/// change can be compared before and after. Run by hand; see
/// docs/CHORES.md, "Build Benchmark".
///
///     bazel run //tools/bench -- [--runs=3] [--scenarios=a,b] [--out=FILE]
///                                [--scratch=DIR] [--keep]
///     bazel run //tools/bench -- compare BEFORE.json AFTER.json
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'bazel.dart';
import 'load.dart';
import 'report.dart';
import 'scenarios.dart';
import 'workspace.dart';

const _usage = '''
usage: bazel run //tools/bench -- [options]
       bazel run //tools/bench -- compare BEFORE.json AFTER.json

options:
  --runs=N          measured runs per scenario (default 3)
  --scenarios=A,B   only these scenarios (default all)
  --out=FILE        the JSON result (default bench-<commit>.json); the table
                    goes beside it as .md, the profiles in a .profiles directory
  --scratch=DIR     where the workspaces and output bases go (default a new
                    temporary directory)
  --keep            keep the scratch directory instead of deleting it''';

Future<void> main(List<String> argv) async {
  // The first three arguments are the runfiles BUILD.bazel passes.
  final runfiles = Runfiles.create();
  final pubSource = File(runfiles.rlocation(argv[0])).parent.path;
  final templates = File(runfiles.rlocation(argv[1])).parent.path;
  final pubTests = File(runfiles.rlocation(argv[2]))
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();
  final args = argv.sublist(3);
  try {
    if (args.isNotEmpty && args.first == 'compare') {
      if (args.length != 3) throw BenchFailure(_usage);
      stdout.write(renderComparison(_read(args[1]), _read(args[2])));
      return;
    }
    await _run(_Options.parse(args), pubSource, templates, pubTests);
  } on BenchFailure catch (e) {
    stderr.writeln('bench: $e');
    exitCode = 1;
  }
}

String _resolve(String path) {
  final cwd = Platform.environment['BUILD_WORKING_DIRECTORY'];
  return path.startsWith('/') || cwd == null ? path : '$cwd/$path';
}

BenchResult _read(String path) => BenchResult.fromJson(
  jsonDecode(File(_resolve(path)).readAsStringSync()) as Map<String, Object?>,
);

class _Options {
  _Options(this.runs, this.chosen, this.out, this.scratch, this.keep);

  final int runs;
  final List<Scenario> chosen;
  final String? out;
  final String? scratch;
  final bool keep;

  static _Options parse(List<String> args) {
    var runs = 3;
    var chosen = scenarios;
    String? out;
    String? scratch;
    var keep = false;
    for (final arg in args) {
      final eq = arg.indexOf('=');
      final key = eq < 0 ? arg : arg.substring(0, eq);
      final value = eq < 0 ? null : arg.substring(eq + 1);
      switch ((key, value)) {
        case ('--runs', final v?) when (int.tryParse(v) ?? 0) > 0:
          runs = int.parse(v);
        case ('--scenarios', final v?):
          final names = v.split(',');
          final unknown = names.where(
            (n) => !scenarios.any((s) => s.name == n),
          );
          if (unknown.isNotEmpty) {
            throw BenchFailure(
              'unknown scenarios ${unknown.join(', ')}; the '
              'scenarios are ${scenarios.map((s) => s.name).join(', ')}',
            );
          }
          chosen = scenarios.where((s) => names.contains(s.name)).toList();
        case ('--out', final v?):
          out = _resolve(v);
        case ('--scratch', final v?):
          scratch = _resolve(v);
        case ('--keep', null):
          keep = true;
        default:
          throw BenchFailure('unknown argument `$arg`\n$_usage');
      }
    }
    return _Options(runs, chosen, out, scratch, keep);
  }
}

Future<void> _run(
  _Options options,
  String pubSource,
  String templates,
  List<String> pubTests,
) async {
  final rulesDart = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (rulesDart == null) throw BenchFailure('run me with `bazel run`');
  final commit = await _git(rulesDart, ['rev-parse', 'HEAD']);
  final dirty = (await _git(rulesDart, [
    'status',
    '--porcelain',
    '--untracked-files=no',
  ])).isNotEmpty;
  final label = commit.substring(0, 12) + (dirty ? '-dirty' : '');
  final out = options.out ?? _resolve('bench-$label.json');
  final stem = out.endsWith('.json') ? out.substring(0, out.length - 5) : out;
  final profiles = Directory('$stem.profiles')..createSync(recursive: true);

  final scratch =
      (options.scratch == null
              ? Directory.systemTemp.createTempSync('rules_dart_bench.')
              : (Directory(options.scratch!)..createSync(recursive: true)))
          .resolveSymbolicLinksSync();
  final log = File('$scratch/bench.log')..writeAsStringSync('');
  Directory('$scratch/events').createSync();
  stderr.writeln('bench: scratch directory $scratch, log ${log.path}');

  Bazel bazelIn(String name) => Bazel(
    workspace: '$scratch/$name',
    outputBase: '$scratch/output_bases/$name',
    eventsDir: '$scratch/events',
    profilesDir: profiles.path,
    log: log,
    ownOutputBases: [scratch],
  );
  final pub = bazelIn('pub');
  final codegen = bazelIn('codegen');

  // Before the bench's own builds raise it.
  final load = await sampleStartLoad([scratch]);
  final bench = Bench(
    runs: options.runs,
    pub: pub,
    pubDir: pub.workspace,
    pubTests: pubTests,
    codegen: codegen,
    codegenDir: codegen.workspace,
  )..warnings.addAll(load.warnings);
  for (final w in load.warnings) {
    stderr.writeln('bench: WARNING: $w');
  }

  final sources = Sources(
    rulesDart: rulesDart,
    pubSource: pubSource,
    templates: templates,
  );
  final results = <ScenarioResult>[];
  try {
    if (options.chosen.any((s) => !s.usesCodegen)) {
      stderr.writeln('bench: setting up dart-lang/pub');
      await setUpPub(sources, pub.workspace, pub);
    }
    if (options.chosen.any((s) => s.usesCodegen)) {
      stderr.writeln('bench: setting up e2e/examples');
      await setUpCodegen(sources, codegen.workspace);
    }
    for (final scenario in options.chosen) {
      // Only one workspace's server runs at a time.
      await (scenario.usesCodegen ? pub : codegen).shutdown();
      stderr.writeln('bench: ${scenario.name}');
      try {
        results.add(
          ScenarioResult(
            scenario.name,
            scenario.description,
            await scenario.measure(bench),
          ),
        );
      } on BenchFailure catch (e) {
        bench.warnings.add('${scenario.name} did not finish: $e');
        stderr.writeln('bench: ${scenario.name} did not finish: $e');
      }
    }
  } finally {
    await pub.shutdown();
    await codegen.shutdown();
    if (options.keep) {
      stderr.writeln('bench: kept $scratch');
    } else {
      await Process.run('chmod', ['-R', 'u+w', scratch]);
      Directory(scratch).deleteSync(recursive: true);
    }
  }

  final result = BenchResult(
    rulesDart: {'commit': commit, 'dirty': dirty},
    date: DateTime.now().toUtc().toIso8601String(),
    environment: {
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'cpus': Platform.numberOfProcessors,
      'bazel_version': results
          .expand((s) => s.runs)
          .map((r) => r.metrics.bazelVersion)
          .firstWhere((v) => v != null, orElse: () => null),
      'load_at_start': load.toJson(),
    },
    warnings: bench.warnings,
    scenarios: results,
  );
  final table = renderTable(result);
  File(out).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(result.toJson()),
  );
  File('$stem.md').writeAsStringSync(table);
  stdout
    ..write(table)
    ..writeln()
    ..writeln('Wrote $out, $stem.md and ${profiles.path}');
}

Future<String> _git(String dir, List<String> args) async {
  final r = await Process.run('git', ['-C', dir, ...args]);
  if (r.exitCode != 0) throw BenchFailure('git ${args.join(' ')}: ${r.stderr}');
  return (r.stdout as String).trim();
}
