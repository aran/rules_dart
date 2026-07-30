import 'dart:io';

/// The BUILD file's `defines` must reach `String.fromEnvironment`. They are
/// resolved by the front end when the test's kernel is compiled, so a value
/// missing here cannot be recovered at run time — the VM's `-D` does not
/// apply to an already-compiled kernel.
void main() {
  const greeting = String.fromEnvironment('GREETING', defaultValue: 'UNSET');
  if (greeting != 'hello from bazel') {
    stderr.writeln('expected GREETING to be defined, got "$greeting"');
    exit(1);
  }

  // A key with no `defines` entry still falls back to its default.
  const missing = String.fromEnvironment('NOT_SET', defaultValue: 'fallback');
  if (missing != 'fallback') {
    stderr.writeln('expected the default for an undefined key, got "$missing"');
    exit(1);
  }

  print('defines reached the compiled kernel: $greeting');
}
