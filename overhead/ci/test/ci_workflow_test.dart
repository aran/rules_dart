import 'package:overhead_ci/ci_workflow.dart';
import 'package:test/test.dart';

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
  defaults-job:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: e2e/d
    steps:
      - uses: actions/checkout@v7
      - run: bazel test //...
      - working-directory: .
        run: echo root
  canary:
    continue-on-error: true
    runs-on: ubuntu-latest
    steps:
      - run: bazel test //...
  conclusion:
    needs: [test, matrix-job, steps-job, defaults-job]
    runs-on: ubuntu-latest
    steps:
      - run: exit 0
''';

void main() {
  final workflow = CiWorkflow.parse(_workflow);

  test('reads a bazel.yaml job\'s folders and command', () {
    expect(workflow.job('test').folders, ['.', 'e2e/smoke', 'e2e/a']);
    expect(
      workflow.job('test').bazelTestCommand,
      startsWith("bash -c 'bazel test //...;"),
    );
    expect(workflow.job('steps-job').folders, isEmpty);
  });

  test('reads the folders where finding no test passes', () {
    expect(workflow.job('test').noTestFolders, {'e2e/a', 'e2e/smoke'});
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

  test('a run step without a directory takes the job\'s default, an action '
      'does not', () {
    expect(
      [for (final s in workflow.job('defaults-job').steps) s.workingDirectory],
      ['.', 'e2e/d', '.'],
    );
  });

  test('a run step takes the workflow\'s default when its job has none', () {
    final withDefault = CiWorkflow.parse(
      'defaults:\n  run:\n    working-directory: e2e/w\n$_workflow',
    );
    expect(
      [for (final s in withDefault.job('steps-job').steps) s.workingDirectory],
      ['e2e/c'],
    );
    expect(
      [for (final s in withDefault.job('canary').steps) s.workingDirectory],
      ['e2e/w'],
    );
  });

  test('a matrix the file does not list cannot be read', () {
    final planned = CiWorkflow.parse(r'''
jobs:
  e2e:
    strategy:
      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}
    steps:
      - working-directory: e2e/${{ matrix.workspace }}
        run: bazel test //...
''');
    expect(
      () => planned.job('e2e').steps,
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('names `matrix.workspace`, which is not a list'),
        ),
      ),
    );
  });

  test('a job that may fail stays out of the gate, the rest are in it', () {
    expect(workflow.gateProblems(), isEmpty);
  });

  test('a blocking job left out of the gate is reported', () {
    final unlisted = CiWorkflow.parse(
      _workflow.replaceFirst(
        'needs: [test, matrix-job, steps-job, defaults-job]',
        'needs: [test, steps-job, defaults-job]',
      ),
    );
    expect(unlisted.gateProblems(), [contains('`matrix-job` is not in')]);
  });

  test('a non-blocking job in the gate, and a missing one, are reported', () {
    final wrong = CiWorkflow.parse(
      _workflow.replaceFirst(
        'needs: [test, matrix-job, steps-job, defaults-job]',
        'needs: [test, matrix-job, steps-job, defaults-job, canary, gone]',
      ),
    );
    expect(wrong.gateProblems(), [
      contains('`canary` has `continue-on-error: true`'),
      contains('names `gone`, which is not a job'),
    ]);
  });

  test('a workflow with no gate job is reported', () {
    final ungated = CiWorkflow.parse('''
jobs:
  test:
    steps:
      - run: bazel test //...
''');
    expect(ungated.gateProblems(), [contains('no `conclusion` job')]);
  });

  test('every workspace some job runs in passes', () {
    expect(
      workflow.unrunWorkspaces(['.', 'e2e/smoke', 'e2e/a', 'e2e/b', 'e2e/c']),
      isEmpty,
    );
  });

  test('a workspace no job runs in is reported', () {
    expect(
      workflow.unrunWorkspaces(['.', 'e2e/a', 'e2e/a/own', 'e2e/forgotten']),
      ['e2e/a/own', 'e2e/forgotten'],
    );
  });
}
