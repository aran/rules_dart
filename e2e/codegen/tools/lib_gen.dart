import 'dart:io';

/// Emits a standalone library (not a `part`) defining `generatedValue()`,
/// consumed via `import` (relative or `package:`).
/// Contract: dart lib_gen.dart --input <src> --output <path> [--input-asset ...]
void main(List<String> args) {
  String? output;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--output') output = args[i + 1];
  }
  if (output == null) {
    stderr.writeln('Usage: lib_gen.dart --input <file> --output <file>');
    exit(1);
  }
  File(output).writeAsStringSync('''
// GENERATED CODE - DO NOT MODIFY BY HAND
String generatedValue() => 'generated lib works';
''');
}
