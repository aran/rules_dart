import 'dart:io';

/// Emits one compiler's variant of `package:i64`'s generated part.
///
/// A generator cannot see the web compiler (codegen is built once, for every
/// compiler), so it is run once per variant, each in its own package, and the
/// library using them picks one with a `select()`.
void main(List<String> args) {
  String? output;
  String? variant;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--output') output = args[i + 1];
    if (args[i] == '--variant') variant = args[i + 1];
  }
  if (output == null || variant == null) {
    stderr.writeln('Usage: variant_gen.dart --output <file> --variant <name>');
    exit(1);
  }
  final type = variant == 'js' ? 'List<int>' : 'Int64List';
  final make = variant == 'js'
      ? 'List<int>.filled(length, 0)'
      : 'Int64List(length)';
  File(output).writeAsStringSync('''
// GENERATED CODE - DO NOT MODIFY BY HAND
part of 'i64.dart';

/// The variant this program was built with.
const String variant = 'i64 variant $variant';

/// A list of 64-bit integers, as this compiler represents one.
typedef I64List = $type;

/// A zeroed [I64List] of [length] elements.
I64List makeI64List(int length) => $make;
''');
}
