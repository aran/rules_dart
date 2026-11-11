import 'package:test/test.dart';

import 'ci_workflow.dart';

const _workflow = r'''
jobs:
  test:
    uses: some/workflow.yaml@v1
    with:
      bazel_test_command: "bash -c 'bazel test //...; s=$?; [ $s -eq 4 ] && case $PWD in */e2e/a|*/e2e/smoke) exit 0;; esac; exit $s'"
      folders: |
        [".", "e2e/smoke", "./e2e/a/"]
  matrix-job:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        folder: [".", "e2e/b"]
    steps:
      - uses: actions/checkout@v7
      - name: test ${{ matrix.folder }}
        working-directory: ${{ matrix.folder }}
        run: bazel test //...
  steps-job:
    runs-on: ubuntu-latest
    steps:
      - name: c fails
        working-directory: e2e/c
        run: |
          ! bazel build //...
  canary:
    continue-on-error: true
    runs-on: ubuntu-latest
    steps:
      - run: bazel test //...
  conclusion:
    needs: [test, matrix-job, steps-job]
    runs-on: ubuntu-latest
    steps:
      - run: exit 0
''';

void main() {
  final workflow = CiWorkflow.parse(_workflow);

  test('reads the test job\'s folders and command', () {
    expect(workflow.testFolders, ['.', 'e2e/smoke', 'e2e/a']);
    expect(workflow.testCommand, startsWith("bash -c 'bazel test //...;"));
  });

  test('reads the folders where finding no test passes', () {
    expect(workflow.noTestFolders, {'e2e/a', 'e2e/smoke'});
  });

  test('expands a matrix working directory into one step per value', () {
    expect(
      [for (final s in workflow.job('matrix-job').steps) s.workingDirectory],
      ['.', '.', 'e2e/b'],
    );
  });

  test('reads a step\'s directory and script', () {
    final [step] = workflow.job('steps-job').steps;
    expect(step.name, 'c fails');
    expect(step.workingDirectory, 'e2e/c');
    expect(step.run, '! bazel build //...\n');
  });

  test('a job that may fail stays out of the gate, the rest are in it', () {
    expect(workflow.gateProblems(), isEmpty);
  });

  test('a blocking job left out of the gate is reported', () {
    final unlisted = CiWorkflow.parse(
      _workflow.replaceFirst(
        'needs: [test, matrix-job, steps-job]',
        'needs: [test, steps-job]',
      ),
    );
    expect(unlisted.gateProblems(), [contains('`matrix-job` is not in')]);
  });

  test('a non-blocking job in the gate, and a missing one, are reported', () {
    final wrong = CiWorkflow.parse(
      _workflow.replaceFirst(
        'needs: [test, matrix-job, steps-job]',
        'needs: [test, matrix-job, steps-job, canary, gone]',
      ),
    );
    expect(wrong.gateProblems(), [
      contains('`canary` has `continue-on-error: true`'),
      contains('names `gone`, which is not a job'),
    ]);
  });

  test('every e2e workspace some job runs in passes', () {
    expect(
      workflow.unrunWorkspaces([
        'MODULE.bazel',
        'e2e/smoke/MODULE.bazel',
        'e2e/a/MODULE.bazel',
        'e2e/b/MODULE.bazel',
        'e2e/c/MODULE.bazel',
        // A module e2e/a depends on, with no lock of its own.
        'e2e/a/dep/MODULE.bazel',
      ]),
      isEmpty,
    );
  });

  test('a workspace no job runs in is reported, nested ones with a lock '
      'included', () {
    expect(
      workflow.unrunWorkspaces([
        'e2e/smoke/MODULE.bazel',
        'e2e/forgotten/MODULE.bazel',
        'e2e/a/MODULE.bazel',
        'e2e/a/own/MODULE.bazel',
        'e2e/a/own/MODULE.bazel.lock',
      ]),
      ['e2e/a/own', 'e2e/forgotten'],
    );
  });
}
