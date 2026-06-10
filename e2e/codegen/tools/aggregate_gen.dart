import 'dart:io';

/// Aggregate-stage generator: records the asset paths the rule layer
/// computed for the primary input and every extra input, plus each extra's
/// content (read from its exec path). Lets tests assert that generated
/// inputs reaching `dart_aggregate_codegen` carry correct in-package asset
/// paths even when the codegen targets live in a different Bazel package
/// than the Dart package root.
///
/// Contract (subset of the shim contract):
///   --input <path> --input-asset <asset> --output <path>
///   --input-asset-extra <exec>|<asset>   (repeatable)
void main(List<String> args) {
  String? inputAsset;
  String? output;
  final extras = <String>[];
  for (var i = 0; i < args.length - 1; i++) {
    switch (args[i]) {
      case '--input-asset':
        inputAsset = args[i + 1];
      case '--output':
        output = args[i + 1];
      case '--input-asset-extra':
        extras.add(args[i + 1]);
    }
  }
  if (inputAsset == null || output == null) {
    stderr.writeln(
        'Usage: aggregate_gen.dart --input-asset <asset> --output <file> '
        '[--input-asset-extra <exec>|<asset> ...]');
    exit(1);
  }
  final buf = StringBuffer()..writeln('// input-asset: $inputAsset');
  for (final extra in extras) {
    final sep = extra.indexOf('|');
    final exec = extra.substring(0, sep);
    final asset = extra.substring(sep + 1);
    buf
      ..writeln('// extra-asset: $asset')
      ..writeln('// extra-content: ${File(exec).readAsStringSync().trim()}');
  }
  File(output).writeAsStringSync(buf.toString());
}
