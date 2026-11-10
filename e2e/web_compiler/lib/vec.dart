import 'package:characters/characters.dart';
import 'package:i64/i64.dart';

/// Which variant of `package:i64` this program was built with, and a list of
/// its type.
String describe() {
  final list = makeI64List(2);
  return '$variant, ${list.length} elements, ${'ok'.characters.length} chars';
}
