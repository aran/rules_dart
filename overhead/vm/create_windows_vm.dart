/// Creates a SPOT Windows VM for the e2e suites (`lib/create_vm.dart`):
///
///     bazel run @overhead//vm:create_windows_vm -- [vm-name] \
///         [--machine-type=e2-standard-4] [--disk-size=100GB]
library;

import 'package:overhead_vm/create_vm.dart';

Future<void> main(List<String> args) => createWindowsVm(args);
