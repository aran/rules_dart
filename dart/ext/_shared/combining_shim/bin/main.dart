/// Combining shim — concatenates SharedPartBuilder `.g.part` shards for a
/// single source into one `.g.dart` with the right `part of` header. Mirrors
/// `source_gen|combining_builder` from build_runner.
///
/// CLI:
///   --input <source.dart>   The original Dart source the parts belong to.
///                           Used only for the `part of` header reference.
///   --output <out.g.dart>   Where to write the combined file.
///   --part <shard.g.part>   Repeatable. Path to a SharedPartBuilder shard.
///
/// Shards are concatenated in lexicographic order for determinism. Any
/// leading `part of '…';` directive on a shard is stripped before
/// concatenation (the combining shim re-emits a single header).
///
/// Worker mode: dispatches on `--persistent_worker`. Each WorkRequest is
/// handled as an independent combine invocation — no cross-request state.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:bazel_worker/bazel_worker.dart';
import 'package:path/path.dart' as p;

// Matches `source_gen|combining_builder` byte-for-byte.
const _header = '''
// GENERATED CODE - DO NOT MODIFY BY HAND
''';

final _partOfRe = RegExp(
    r'''^\s*part of (?:'[^']+'|"[^"]+");\s*''',
    multiLine: true);

Future<void> main(List<String> argv) async {
  if (argv.contains('--persistent_worker')) {
    await _CombiningWorker().run();
    return;
  }
  await _runOnce(_expandFlagFiles(argv));
}

class _CombiningWorker extends AsyncWorkerLoop {
  @override
  Future<WorkResponse> performRequest(WorkRequest request) async {
    final buf = StringBuffer();
    final sink = (String msg) => buf.writeln(msg);
    int exit = 0;
    try {
      await runZoned(
        () => _runOnce(request.arguments, sink),
        zoneSpecification:
            ZoneSpecification(print: (_, _, _, line) => buf.writeln(line)),
      );
    } catch (e, st) {
      buf
        ..writeln('combining_shim failed: $e')
        ..writeln(st);
      exit = 1;
    }
    return WorkResponse()
      ..exitCode = exit
      ..output = buf.toString();
  }
}

Future<void> _runOnce(
    List<String> argv, [
    void Function(String)? diagnostic,
]) async {
  final sink = diagnostic ?? stderr.writeln;
  final parser = ArgParser()
    ..addOption('input', mandatory: true)
    ..addOption('output', mandatory: true)
    ..addMultiOption('part')
    ..addOption('input-asset', defaultsTo: '')
    ..addMultiOption('input-asset-extra')
    ..addOption('package', defaultsTo: '')
    ..addOption('package-config', defaultsTo: '')
    ..addMultiOption('dep')
    ..addOption('config', defaultsTo: '')
    ..addOption('root-language-version', defaultsTo: '')
    ..addOption('sdk-path', defaultsTo: '');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on ArgParserException catch (e) {
    sink('Invalid args: ${e.message}\n${parser.usage}');
    exitCode = 2;
    return;
  }

  final String input;
  final String output;
  try {
    input = args['input'] as String;
    output = args['output'] as String;
  } on ArgumentError catch (e) {
    sink('${e.message}\n${parser.usage}');
    exitCode = 2;
    return;
  }
  final parts = ((args['part'] as List).cast<String>())..sort();

  // Shard reads run in parallel via async I/O; this keeps the worker's
  // stdin-reading loop responsive even for large generated `.g.part`
  // shards (drift with many tables can produce multi-hundred-KB shards).
  final contents = await Future.wait(
    [for (final part in parts) File(part).readAsString()],
  );
  await File(output).writeAsString(combine(
    sourceBasename: p.basename(input),
    partContents: contents,
  ));
}

/// Expand any `@<path>` arg by reading the file and splitting on newlines.
/// Mirrors the same expansion in `worker_entry.shimMain` for one-shot mode.
List<String> _expandFlagFiles(List<String> args) {
  final out = <String>[];
  for (final a in args) {
    if (a.startsWith('@') && a.length > 1) {
      for (final line in File(a.substring(1)).readAsStringSync().split('\n')) {
        if (line.isNotEmpty) out.add(line);
      }
    } else if (a.startsWith('--flagfile=')) {
      for (final line in File(a.substring('--flagfile='.length))
          .readAsStringSync()
          .split('\n')) {
        if (line.isNotEmpty) out.add(line);
      }
    } else {
      out.add(a);
    }
  }
  return out;
}

/// Byte-identical layout to `source_gen|combining_builder`: GENERATED
/// header, blank, `part of '<src>';`, blank, shards joined by single
/// blanks with no trailing blank. Unit-tested at package root.
String combine({
  required String sourceBasename,
  required List<String> partContents,
}) {
  final buf = StringBuffer()
    ..write(_header)
    ..writeln()
    ..writeln("part of '$sourceBasename';");

  for (final raw in partContents) {
    final stripped = raw.replaceFirst(_partOfRe, '').trim();
    if (stripped.isEmpty) continue;
    buf
      ..writeln()
      ..writeln(stripped);
  }
  return buf.toString();
}
