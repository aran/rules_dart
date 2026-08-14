import 'dart:io';

/// Asserts must fire at runtime in every Bazel compilation mode: the test
/// runner always passes `--enable-asserts` to the VM, independent of the
/// flags used to compile the kernel.
void main() {
  // Caught as `Object` and narrowed after the fact: an `on AssertionError`
  // clause would trip `avoid_catching_errors`. Asserts being disabled and
  // some other throw both leave `fired` false, which is the failure below.
  var fired = false;
  try {
    assert(false, 'expected to fire');
  } on Object catch (e) {
    fired = e is AssertionError;
  }
  if (!fired) {
    stderr.writeln('assert(false) did not fire — asserts are disabled');
    exit(1);
  }
  stdout.writeln('Asserts are enabled at runtime.');
}
