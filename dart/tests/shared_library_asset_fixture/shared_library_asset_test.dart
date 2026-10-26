import 'dart:ffi';

@Native<Int32 Function()>(assetId: 'package:a/a.dart', symbol: 'bump')
external int bumpThroughA();

@Native<Int32 Function()>(assetId: 'package:b/b.dart', symbol: 'bump')
external int bumpThroughB();

/// Fails unless both asset ids loaded one image of the shared library: two
/// copies would each keep their own count.
void main() {
  bumpThroughA();
  final count = bumpThroughB();
  if (count != 2) {
    throw StateError('the two asset ids loaded separate copies of the library');
  }
}
