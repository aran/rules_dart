import 'dart:ffi';

@Native<Int32 Function()>(assetId: 'package:c/c.dart', symbol: 'bump')
external int bump();

/// Fails unless the prebuilt library was bundled and loads.
void main() {
  if (bump() != 1) throw StateError('the prebuilt library did not load');
}
