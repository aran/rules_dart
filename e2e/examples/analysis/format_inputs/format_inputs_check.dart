// Asserts that a target's format check reads nothing from its dependencies.
//
// Property: the inputs of the `dart_analyze` aspect's `DartFormat` action are
// what `dart format` reads: the target's own files, the options config and the
// packages that config `include:`s, the formatter and the SDK. So a target
// with a dependency takes exactly the inputs of one without, plus its own file;
// editing a dependency cannot re-run the check.
//
// The inputs are followed to the sources they are made from: the staged
// project is a tree artifact another action assembles, so its direct inputs
// alone say nothing about the sources behind it.
//
// Run from the workspace: `bazel run //analysis/format_inputs`.
import 'dart:convert';
import 'dart:io';

const _top = '//analysis/format_chain/top:top';
const _dep = '//analysis/format_chain/dep:dep';
const _topSrc = 'analysis/format_chain/top/lib/top.dart';
const _depSrc = 'analysis/format_chain/dep/lib/dep.dart';

void main() {
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null) {
    stderr.writeln('run with `bazel run //analysis/format_inputs`');
    exit(2);
  }
  final top = _formatSources(workspace, _top);
  final dep = _formatSources(workspace, _dep);

  final failures = <String>[];
  if (!top.contains(_topSrc)) failures.add('$_top: does not take $_topSrc');
  if (!dep.contains(_depSrc)) failures.add('$_dep: does not take $_depSrc');
  // Dependency-free, a target's check takes the config and its own file.
  final base = dep.difference({_depSrc});
  final withDep = top.difference({_topSrc});
  final extra = withDep.difference(base).toList()..sort();
  final missing = base.difference(withDep).toList()..sort();
  if (extra.isNotEmpty) {
    failures.add(
      '$_top: the format check takes files only its dependency brings, '
      'which `dart format` never reads:\n  ${extra.join('\n  ')}',
    );
  }
  if (missing.isNotEmpty) {
    failures.add(
      '$_top: the format check lacks inputs a dependency-free target has:'
      '\n  ${missing.join('\n  ')}',
    );
  }
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exit(1);
  }
  stdout.writeln('format inputs: ok');
}

/// The leaf files (no action of the graph makes them) that reach [label]'s
/// `DartFormat` action, as exec paths.
Set<String> _formatSources(String workspace, String label) {
  final result = Process.runSync(
    'bazel',
    [
      'aquery',
      '--aspects=@rules_dart//dart:analyze.bzl%dart_analyze',
      '--output_groups=+dart_format',
      '--include_artifacts',
      '--output=jsonproto',
      'deps($label)',
    ],
    workingDirectory: workspace,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    exit(2);
  }
  final graph = jsonDecode(result.stdout as String) as Map<String, dynamic>;

  final fragments = {
    for (final f
        in (graph['pathFragments'] as List).cast<Map<String, dynamic>>())
      f['id'] as int: f,
  };
  String pathOf(int fragment) {
    final f = fragments[fragment]!;
    final parent = f['parentId'] as int?;
    return parent == null
        ? f['label'] as String
        : '${pathOf(parent)}/${f['label']}';
  }

  final artifacts = {
    for (final a in (graph['artifacts'] as List).cast<Map<String, dynamic>>())
      a['id'] as int: pathOf(a['pathFragmentId'] as int),
  };
  final depsets = {
    for (final d
        in (graph['depSetOfFiles'] as List).cast<Map<String, dynamic>>())
      d['id'] as int: d,
  };
  final targets = {
    for (final t in (graph['targets'] as List).cast<Map<String, dynamic>>())
      t['id'] as int: t['label'],
  };

  final actions = (graph['actions'] as List).cast<Map<String, dynamic>>();
  final makers = <int, Map<String, dynamic>>{};
  for (final a in actions) {
    for (final out in (a['outputIds'] as List? ?? const [])) {
      makers[out as int] = a;
    }
  }

  Iterable<int> inputsOf(Map<String, dynamic> action) sync* {
    final seen = <int>{};
    final pending = [...(action['inputDepSetIds'] as List? ?? const [])];
    while (pending.isNotEmpty) {
      final d = depsets[pending.removeLast() as int]!;
      if (!seen.add(d['id'] as int)) continue;
      yield* (d['directArtifactIds'] as List? ?? const []).cast<int>();
      pending.addAll(d['transitiveDepSetIds'] as List? ?? const []);
    }
  }

  final format = actions.singleWhere(
    (a) => a['mnemonic'] == 'DartFormat' && targets[a['targetId']] == label,
    orElse: () => throw StateError('no DartFormat action on $label'),
  );
  final leaves = <String>{};
  final visited = <int>{};
  final pending = inputsOf(format).toList();
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (!visited.add(id)) continue;
    final maker = makers[id];
    if (maker == null) {
      leaves.add(artifacts[id]!);
    } else {
      pending.addAll(inputsOf(maker));
    }
  }
  return leaves;
}
