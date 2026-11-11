// Prints a sum from the library `trim` links into every program.
import 'dart:ffi';
import 'dart:io';

@Native<Int32 Function(Int32, Int32)>(
  symbol: 'trim_add',
  assetId: 'package:trim/ops',
)
external int _add(int a, int b);

void main() => stdout.writeln(_add(2, 3));
