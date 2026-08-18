import 'dart:io';

/// Emits a `part of` companion defining `generatedMessage()`.
/// Contract: `dart part_gen.dart --input <src> --output <path>`,
/// optionally `--input-asset <asset>`.
void main(List<String> args) {
  String? input;
  String? output;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--input') input = args[i + 1];
    if (args[i] == '--output') output = args[i + 1];
  }
  if (input == null || output == null) {
    stderr.writeln('Usage: part_gen.dart --input <file> --output <file>');
    exit(1);
  }
  final libName = Uri.file(input).pathSegments.last;
  File(output).writeAsStringSync('''
// GENERATED CODE - DO NOT MODIFY BY HAND
part of '$libName';

String generatedMessage() => 'generated part works';
''');
}
