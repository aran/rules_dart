import 'dart:io';

/// Emits a one-line metadata shard for the input source — the stand-in for
/// a per-file metadata stage (e.g. injectable's `.injectable.json` shards).
/// Contract: dart shard_gen.dart --input <src> --output <path> [...]
void main(List<String> args) {
  String? input;
  String? output;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--input') input = args[i + 1];
    if (args[i] == '--output') output = args[i + 1];
  }
  if (input == null || output == null) {
    stderr.writeln('Usage: shard_gen.dart --input <file> --output <file>');
    exit(1);
  }
  final base = Uri.file(input).pathSegments.last;
  File(output).writeAsStringSync('shard-for:$base\n');
}
