/// Bazel persistent-worker entry for AOT-compiled shim binaries. Each
/// shim's `main` dispatches on `--persistent_worker`: with the flag,
/// [runShimAsWorker] reads `WorkRequest`s from stdin and runs each in an
/// isolate of its own; without it, [runShim] runs one-shot.
///
/// A fresh isolate per request gives each request the top-level state a
/// one-shot process starts with. Generators keep state there that is meant to
/// last one build: `json_serializable` checks the package's pubspec once and
/// remembers that it did, so a worker that kept it would warn on its first
/// request and never again; `source_gen`'s `rootPackageName` is read from the
/// working directory on first use and kept, so it would name the first
/// request's package in every later one.
///
/// Singleplex only: the working directory, which the shim changes for each
/// request and `source_gen` reads, belongs to the process, not the isolate.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:bazel_worker/bazel_worker.dart';

import 'builder_shim.dart';

/// Runs the shim as a persistent worker. Diagnostics land in
/// `WorkResponse.output` rather than on the stdout/stderr proto streams
/// Bazel reads.
Future<void> runShimAsWorker(Object factoryOrFactories) async {
  final loop = ShimWorkerLoop(factoryOrFactories: factoryOrFactories);
  await loop.run();
}

/// Exposed (rather than kept private) so unit tests can construct the loop
/// and drive [performRequest] directly with a crafted [WorkRequest] — the
/// stdin/stdout framing is [AsyncWorkerLoop]'s responsibility, not ours.
class ShimWorkerLoop extends AsyncWorkerLoop {
  ShimWorkerLoop({required this.factoryOrFactories});

  final Object factoryOrFactories;

  @override
  Future<WorkResponse> performRequest(WorkRequest request) async {
    final factories = factoryOrFactories;
    final arguments = request.arguments.toList();
    final inputs = [for (final input in request.inputs) input.path];
    final (exit, output) = await Isolate.run(
      () => _performRequest(factories, arguments, inputs),
    );
    return WorkResponse()
      ..exitCode = exit
      ..output = output;
  }
}

/// Runs one request in the current isolate; returns its exit code and output.
Future<(int, String)> _performRequest(
  Object factoryOrFactories,
  List<String> arguments,
  List<String> inputs,
) async {
  final stderrBuffer = StringBuffer();
  int exit = 0;

  // Route diagnostics through `WorkResponse.output` rather than the
  // shared worker stderr (Bazel's protocol requires stdout/stderr clean).
  // `runShim`'s own diagnostic paths + the builder Logger listener take
  // the sink; the Zone `print` override catches stray `print()` calls
  // from within builders as a belt-and-suspenders backstop.
  void sink(String message) => stderrBuffer.writeln(message);

  await runZoned(
    () async {
      // `runShim` sets the process's exitCode on failure; reset per
      // request so one bad request doesn't taint the next.
      exitCode = 0;
      try {
        await runShim(
          arguments,
          factoryOrFactories,
          writeDiagnostic: sink,
          // Unsandboxed, the worker could read anything under a package's
          // root; Bazel's contract is that it reads only these.
          declaredInputs: inputs,
        );
        exit = exitCode;
      } catch (e, st) {
        sink('Worker request failed: $e');
        sink(st.toString());
        exit = 1;
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        sink(line);
      },
    ),
  );
  return (exit, stderrBuffer.toString());
}

/// Standard `main` dispatcher for per-builder shim entrypoints: selects
/// worker-loop mode when `--persistent_worker` is present, one-shot
/// otherwise. Every `dart/ext/*/shim*.dart`'s `main` delegates here.
///
/// In one-shot mode, Bazel may send arguments via a single `@<flagfile>`
/// entry (when the rule declares `use_param_file`); we expand it inline.
/// In worker mode Bazel expands the flagfile itself before putting args
/// into `WorkRequest.arguments`, so no expansion is needed there.
///
/// `sdk-summary --sdk <dir> --out <file>` writes the summary of the SDK at
/// `<dir>` that `--sdk-summary` reads ([writeSdkSummary]).
Future<void> shimMain(List<String> args, Object factoryOrFactories) async {
  if (args.contains('--persistent_worker')) {
    await runShimAsWorker(factoryOrFactories);
    return;
  }
  final expanded = expandFlagFiles(args);
  if (expanded.firstOrNull == 'sdk-summary') {
    await writeSdkSummary(expanded.sublist(1));
    return;
  }
  await runShim(expanded, factoryOrFactories);
}

/// Expand any `@<path>` argument by reading the file and splitting on
/// newlines, inlining the results. Non-flagfile args pass through
/// unchanged. Matches Bazel's `@file` / `--flagfile=` convention for
/// non-worker actions. Trims each line so CRLF flagfiles (Windows, or
/// tools that emit `\r\n`) don't leak `\r` into argument tokens — a
/// trailing `\r` would make `ArgParser.parse` reject `--input\r` as
/// unknown.
///
/// Exposed (rather than private) to support direct unit tests.
List<String> expandFlagFiles(List<String> args) {
  final out = <String>[];
  for (final a in args) {
    if (a.startsWith('@') && a.length > 1) {
      _appendFlagFileLines(File(a.substring(1)).readAsStringSync(), out);
    } else if (a.startsWith('--flagfile=')) {
      final path = a.substring('--flagfile='.length);
      _appendFlagFileLines(File(path).readAsStringSync(), out);
    } else {
      out.add(a);
    }
  }
  return out;
}

void _appendFlagFileLines(String content, List<String> out) {
  for (final raw in content.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isNotEmpty) out.add(line);
  }
}
