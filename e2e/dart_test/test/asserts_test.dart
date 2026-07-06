import 'dart:io';

/// Asserts must fire at runtime in every Bazel compilation mode: the test
/// runner always passes `--enable-asserts` to the VM, independent of the
/// flags used to compile the kernel.
void main() {
  var fired = false;
  try {
    assert(false, 'expected to fire');
  } on AssertionError {
    fired = true;
  }
  if (!fired) {
    stderr.writeln('assert(false) did not fire — asserts are disabled');
    exit(1);
  }
  print('Asserts are enabled at runtime.');
}
