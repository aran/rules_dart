// Property: `bazel run @rules_dart//dart/format` formats a file under the
// options its format check applies, here a page width from a ruleset another
// Bazel module shares by `package:` include, which the SDK's own formatter run
// over the workspace could not resolve.
//
// The fixture is this workspace's own source, so it is put back afterwards,
// whatever happened.
//
// Run from the workspace: `bazel run //shared_lint_rules/format_run`.
import 'dart:io';

const _fixture = 'shared_lint_rules/wide/lib/wide.dart';
const _golden = 'shared_lint_rules/wide/golden/wide.dart';

void main() {
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null) {
    stderr.writeln('run with `bazel run //shared_lint_rules/format_run`');
    exit(2);
  }
  final fixture = File('$workspace/$_fixture');
  final golden = File('$workspace/$_golden').readAsStringSync();
  final original = fixture.readAsStringSync();
  if (original == golden) {
    stderr.writeln('$_fixture is already formatted; restore it');
    exit(2);
  }

  String? failure;
  try {
    final result = Process.runSync('bazel', [
      'run',
      '@rules_dart//dart/format',
      '--',
      '//shared_lint_rules/wide',
    ], workingDirectory: workspace);
    if (result.exitCode != 0) {
      failure = 'format exited ${result.exitCode}:\n${result.stdout}${result.stderr}';
    } else if (fixture.readAsStringSync() != golden) {
      failure =
          '$_fixture is not as $_golden has it:\n'
          '${fixture.readAsStringSync()}';
    }
  } finally {
    fixture.writeAsStringSync(original);
  }

  if (failure != null) {
    stderr.writeln(failure);
    exit(1);
  }
  stdout.writeln('format run: ok');
}
