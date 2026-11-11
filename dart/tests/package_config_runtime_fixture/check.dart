// Fails unless the VM was given rules_dart's empty package config: one found
// by looking up from the program, the workspace's own `.dart_tool` when the
// run is not sandboxed, would make the program depend on a file no target
// declares.
import 'dart:isolate';

Future<void> main() async {
  final config = await Isolate.packageConfig;
  if (config == null || !config.path.endsWith('/empty_package_config.json')) {
    throw StateError('the VM read the package config $config');
  }
}
