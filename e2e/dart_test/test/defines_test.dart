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

  // Set only by `--@rules_dart//dart:extra_dart_defines` in this workspace's
  // .bazelrc — no target names it, which is the point of the flag.
  const fromFlag = String.fromEnvironment('E2E_FLAG', defaultValue: 'UNSET');
  if (fromFlag != 'from_flag') {
    stderr.writeln('expected the extra_dart_defines flag to reach the compile, '
        'got "$fromFlag"');
    exit(1);
  }

  // Set by both the attr and the flag. Flag values are appended last and every
  // Dart compiler takes the last `-D` for a repeated key, so the flag wins.
  const winner = String.fromEnvironment('E2E_WINNER', defaultValue: 'UNSET');
  if (winner != 'flag') {
    stderr.writeln('expected the flag to win over the attr, got "$winner"');
    exit(1);
  }

  print('defines reached the compiled kernel: $greeting');
}
