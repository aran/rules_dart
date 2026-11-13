// Calls into the library `trim` links into every program: a test loads it as
// its program ships it.
import 'dart:ffi';
import 'dart:io';

@Native<Int32 Function(Int32, Int32)>(
  symbol: 'trim_mul',
  assetId: 'package:trim/ops',
)
external int _mul(int a, int b);

void main() {
  if (_mul(6, 7) != 42) {
    stdout.writeln('FAIL: trim_mul(6, 7) = ${_mul(6, 7)}');
    exit(1);
  }
}
