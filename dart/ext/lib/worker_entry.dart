/// Bazel persistent-worker entry for AOT-compiled shim binaries. Each
/// shim's `main` dispatches on `--persistent_worker`: with the flag,
/// [runShimAsWorker] reads `WorkRequest`s from stdin and constructs a
/// fresh analyzer context per request; without it, [runShim] runs one-shot.
///
/// Singleplex only, for two reasons: (1) `source_gen`'s `rootPackageName`
/// is a CWD-reading top-level `final`, so concurrent in-process requests
/// would race on CWD; (2) `rootPackageName` is initialized lazily on first
/// access and pinned thereafter — any `file:`-URI path through
/// `source_gen`'s `normalizeUrl` / `urlOfElement` silently uses the
/// first-request's package name for every subsequent request. The
/// `package:`-URI path (the hot path in our shims) is unaffected, but new
/// builders or analyzer-integration changes that touch `file:` URIs can
/// cross-contaminate silently.
library;

import 'dart:async';
import 'dart:io';

import 'package:bazel_worker/bazel_worker.dart';
import 'package:build/build.dart';

import 'builder_shim.dart';

/// Runs the shim as a persistent worker. Diagnostics are captured via Zone
/// so they land in `WorkResponse.output` rather than corrupting the
/// stdout/stderr proto streams Bazel reads.
Future<void> runShimAsWorker(
  Object factoryOrFactories, {
  EmptyOutputHook? emptyOutput,
}) async {
  final loop = ShimWorkerLoop(
    factoryOrFactories: factoryOrFactories,
    emptyOutput: emptyOutput,
  );
  await loop.run();
}

/// Exposed (rather than kept private) so unit tests can construct the loop
/// and drive [performRequest] directly with a crafted [WorkRequest] — the
/// stdin/stdout framing is [AsyncWorkerLoop]'s responsibility, not ours.
class ShimWorkerLoop extends AsyncWorkerLoop {
  ShimWorkerLoop({
    required this.factoryOrFactories,
    this.emptyOutput,
  });

  final Object factoryOrFactories;
  final EmptyOutputHook? emptyOutput;

  @override
  Future<WorkResponse> performRequest(WorkRequest request) async {
    final stderrBuffer = StringBuffer();
    int exit = 0;

    // Respect WorkRequest.sandboxDir when set (Bazel populates it with
    // `--experimental_sandboxed_worker`): rooted staging there means
    // per-request hermeticity lines up with Bazel's sandbox lifecycle.
    // When unset (the default), fall back to the system temp dir.
    Directory? stagingRoot;
    if (request.sandboxDir.isNotEmpty) {
      stagingRoot = Directory(request.sandboxDir);
      if (!await stagingRoot.exists()) {
        await stagingRoot.create(recursive: true);
      }
    }

    // Route diagnostics through `WorkResponse.output` rather than the
    // shared worker stderr (Bazel's protocol requires stdout/stderr clean).
    // `runShim`'s own diagnostic paths + the builder Logger listener take
    // the sink; the Zone `print` override catches stray `print()` calls
    // from within builders as a belt-and-suspenders backstop.
    void sink(String message) => stderrBuffer.writeln(message);

    await runZoned(
      () async {
        // `runShim` sets the top-level exitCode on failure; reset per
        // request so one bad request doesn't taint the next.
        exitCode = 0;
        try {
          await runShim(
            request.arguments,
            factoryOrFactories,
            emptyOutput: emptyOutput,
            stagingRoot: stagingRoot,
            writeDiagnostic: sink,
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
      zoneValues: {},
    );

    return WorkResponse()
      ..exitCode = exit
      ..output = stderrBuffer.toString();
  }
}

/// Standard `main` dispatcher for per-builder shim entrypoints: selects
/// worker-loop mode when `--persistent_worker` is present, one-shot
/// otherwise. Every `dart/ext/*/shim*.dart`'s `main` delegates here.
///
/// In one-shot mode, Bazel may send arguments via a single `@<flagfile>`
/// entry (when the rule declares `use_param_file`); we expand it inline.
/// In worker mode Bazel expands the flagfile itself before putting args
/// into `WorkRequest.arguments`, so no expansion is needed there.
Future<void> shimMain(
  List<String> args,
  Object factoryOrFactories, {
  EmptyOutputHook? emptyOutput,
}) async {
  if (args.contains('--persistent_worker')) {
    await runShimAsWorker(factoryOrFactories, emptyOutput: emptyOutput);
    return;
  }
  await runShim(
    expandFlagFiles(args),
    factoryOrFactories,
    emptyOutput: emptyOutput,
  );
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
