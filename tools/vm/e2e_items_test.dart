import 'package:overhead_ci/ci_workflow.dart';
import 'package:overhead_vm/e2e.dart';
import 'package:test/test.dart';

import 'e2e_items.dart';

const _workflow = r'''
jobs:
  test:
    uses: some/workflow.yaml@v1
    with:
      bazel_test_command: "bash -c 'bazel test //...; s=$?; [ $s -eq 4 ] && case $PWD in */e2e/a) exit 0;; esac; exit $s'"
      folders: |
        [".", "e2e/a", "e2e/b"]
  expected-failure:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: c fails
        working-directory: e2e/c
        run: |
          ! bazel build //...
''';

void main() {
  final ci = CiWorkflow.parse(_workflow);
  List<String> described(List<E2eItem> items) => [
    for (final i in items)
      '${i.name} @ ${i.folder}: '
          '${i.script ?? i.bazelArgs!.join(' ')} ${i.passExitCodes}',
  ];

  test('Linux runs every test folder, then the expected failures', () {
    expect(described(e2eItems(ci, E2eOptions(vm: 'v'))), [
      '. @ .: ${ci.job(testJob).bazelTestCommand} {0}',
      'e2e/a @ e2e/a: ${ci.job(testJob).bazelTestCommand} {0}',
      'e2e/b @ e2e/b: ${ci.job(testJob).bazelTestCommand} {0}',
      'e2e/c: c fails @ e2e/c: ! bazel build //...\n {0}',
    ]);
  });

  test('--folders runs the test command there, and no expected failure', () {
    expect(
      described(e2eItems(ci, E2eOptions(vm: 'v', folders: ['e2e/b', 'e2e/z']))),
      [
        'e2e/b @ e2e/b: ${ci.job(testJob).bazelTestCommand} {0}',
        'e2e/z @ e2e/z: ${ci.job(testJob).bazelTestCommand} {0}',
      ],
    );
  });

  test('Windows runs bazel test, passing on 4 where CI does', () {
    expect(described(e2eItems(ci, E2eOptions(vm: 'v', windows: true))), [
      '. @ .: test --test_output=errors //... {0}',
      'e2e/a @ e2e/a: test --test_output=errors //... {0, 4}',
      'e2e/b @ e2e/b: test --test_output=errors //... {0}',
    ]);
  });
}
