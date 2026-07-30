/// Fails unless `defines` reached the build-time kernel compile.
///
/// `dart_test` compiles `main` to a kernel during the build and the launcher
/// only runs it, so a declaration that misses that compile cannot be supplied
/// later — the VM's own `-D` has no effect on an already-compiled kernel.
void main() {
  const channel = String.fromEnvironment('CHANNEL', defaultValue: 'UNSET');
  if (channel != 'runtime') {
    throw StateError('expected CHANNEL=runtime, got "$channel"');
  }
}
