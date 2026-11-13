/// What rules_dart runs on a test VM: what `.github/workflows/ci.yaml` runs.
library;

import 'package:overhead_vm/e2e.dart';

import '../../tool/ci_workflow.dart';

/// The job whose steps each check a failure rules_dart must report.
const expectedFailureJob = 'expected-failure';

/// What CI runs, from [workflow], as [options] select it.
///
/// On Linux, the `test` job's command in each of its folders, then, when
/// `--folders` names none, every step of the expected-failure job in its
/// working directory. On Windows, where the command is bash, `bazel test
/// //...` in each folder, which also passes on exit 4 (no test target) where
/// the command does.
///
/// `--folders` runs the test command in each folder it names, CI's or not.
List<E2eItem> e2eItems(CiWorkflow workflow, E2eOptions options) {
  final folders = options.folders ?? workflow.testFolders;
  if (options.windows) {
    final noTests = workflow.noTestFolders;
    return [
      for (final folder in folders)
        E2eItem.bazel(folder, const [
          'test',
          '--test_output=errors',
          '//...',
        ], passExitCodes: noTests.contains(folder) ? const {0, 4} : const {0}),
    ];
  }
  return [
    for (final folder in folders) E2eItem.script(folder, workflow.testCommand),
    if (options.folders == null)
      for (final step in workflow.job(expectedFailureJob).steps)
        if (step.run case final script?)
          E2eItem.script(
            step.workingDirectory,
            script,
            name: '${step.workingDirectory}: ${step.name}',
          ),
  ];
}
