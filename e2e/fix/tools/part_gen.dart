// Stands in for a real builder (freezed, json_serializable, …).
//
// Which builder produced a file is irrelevant to `dart_fix`: eligibility is
// decided from `File.is_source`, so all that matters here is that Bazel records
// the output as generated. What the generated code contains does matter — the
// hand-written library resolves `ModelBase` and `modelLabel` out of these parts
// while the fix rule has them excluded.
//
// Contract (the subset of the shim contract this needs):
//   --input <path> --output <path> [--violation]
import 'dart:io';

void main(List<String> args) {
  String? input;
  String? output;
  var violation = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--input':
        input = args[++i];
      case '--output':
        output = args[++i];
      case '--violation':
        violation = true;
    }
  }
  if (input == null || output == null) {
    stderr.writeln(
      'Usage: part_gen.dart --input <file> --output <file> [--violation]',
    );
    exit(64);
  }

  // `prefer_final_locals` fires on `var`, so one keyword is the whole
  // difference between a part `dart fix` wants to rewrite and one it does not.
  final keyword = violation ? 'var' : 'final';
  final body = output.endsWith('.g.dart')
      ? '''
abstract class ModelBase {
  String describe();

  String tag() {
    $keyword value = 'g';
    return value;
  }
}
'''
      : '''
String modelLabel() {
  $keyword label = 'generated';
  return label;
}
''';

  File(output).writeAsStringSync('''
// GENERATED CODE - DO NOT MODIFY BY HAND
part of '${Uri.file(input).pathSegments.last}';

$body''');
}
