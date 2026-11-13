/// Creates a SPOT Linux VM for the e2e suites (`lib/create_vm.dart`):
///
///     bazel run @overhead//vm:create_linux_vm -- [vm-name] \
///         [--machine-type=e2-standard-4] [--disk-size=60GB]
library;

import 'package:overhead_vm/create_vm.dart';

Future<void> main(List<String> args) => createLinuxVm(args);
