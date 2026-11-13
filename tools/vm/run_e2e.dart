/// Runs rules_dart's e2e suites on a test VM, as `.github/workflows/ci.yaml`
/// at HEAD runs them (`e2e_items.dart`):
///
///     bazel run @overhead//vm:create_linux_vm -- <vm-name>
///     bazel run //tools/vm:run_e2e -- <vm-name> [--windows] \
///         [--folders=e2e/smoke,e2e/examples] [--keep-going] \
///         [--remote-cache=https://storage.googleapis.com/<bucket>]
///     gcloud compute instances delete <vm-name> --quiet
///
/// overhead's runner (`@overhead//vm`, lib/e2e.dart) does the rest: it runs
/// the committed HEAD, not the working tree.
library;

import 'dart:io';

import 'package:overhead_ci/ci_workflow.dart';
import 'package:overhead_vm/e2e.dart';

import 'e2e_items.dart';

Future<void> main(List<String> args) => runE2e(
  args,
  repo: 'rules_dart',
  usage:
      'Runs what ci.yaml at HEAD runs: the test job in each of its folders '
      'and, on Linux without --folders, the $expectedFailureJob job.',
  items: (options, root) {
    final ci = Process.runSync('git', [
      '-C',
      root,
      'show',
      'HEAD:.github/workflows/ci.yaml',
    ]);
    if (ci.exitCode != 0) throw Exception('git show failed: ${ci.stderr}');
    return e2eItems(CiWorkflow.parse(ci.stdout as String), options);
  },
);
