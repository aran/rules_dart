import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:runfiles/runfiles.dart';

import 'coverage_lcov.dart';

/// Converts line coverage that a Dart VM reported, as `package:coverage` writes
/// it, into the LCOV tracefile Bazel's coverage runner merges, naming each
/// file by its path in the workspace.
///
///     coverage_converter --hitmaps=<dir> --sources=<file> --output=<file>
///
/// This is public: `@rules_dart//dart:coverage_converter`. A test rule that
/// collects coverage from a VM of its own runs it inside the test, under
/// `bazel coverage`.
///
/// * `--hitmaps=<dir>`: a directory holding the coverage, in files ending
///   `.json` at any depth. Each file is what `package:coverage`'s `collect`
///   returns, JSON with a `coverage` list of `{source, script, hits}` entries,
///   `hits` being line and hit-count pairs flattened; the counts of one script
///   in several files add. A directory that does not exist is an empty report
///   (a test run that ran no suite collected none).
/// * `--sources=<file>`: the file `test_coverage` in `@rules_dart//dart:utils.bzl`
///   writes, which names where each package's `lib/` directories are and the
///   runfiles path of each source Bazel instruments.
/// * `--output=<file>`: where the tracefile goes, `$COVERAGE_DIR/<name>.dat`:
///   the coverage runner merges every `*.dat` in `COVERAGE_DIR`.
///
/// Bazel's `COVERAGE_MANIFEST`, which lists the files the test instruments by
/// path from the exec root, must be set, as Bazel does for a test it runs
/// under `bazel coverage`. A script is reported under its path there, and one
/// that is not listed (the SDK's, a generated entrypoint's, a library
/// `--instrumentation_filter` leaves out) is not reported. The URIs a script
/// has are `package:<name>/<path>`, found through the `lib/` directories of
/// the package, and `org-dartlang-root:///<path>`, found by its path below the
/// kernel roots, which is the one Dart kernels `dart_test` and `dart_binary`
/// compile have.
///
/// A line a source marks `// coverage:ignore-line`, the lines from a
/// `// coverage:ignore-start` to the next `// coverage:ignore-end`, and the
/// whole file for a `// coverage:ignore-file`, are left out of the tracefile,
/// as `dart test --coverage-path` leaves them out. The sources are read from
/// the runfiles of the test this runs in (its `RUNFILES_DIR` or manifest, which
/// a process the test starts inherits); a source missing there, or an
/// unbalanced marker, is a failure.
///
/// Exit status 0 is success, 2 a usage error (a missing flag or a missing
/// `COVERAGE_MANIFEST`), and anything else a failure, with a message on stderr.
Future<void> main(List<String> args) async {
  final values = <String, String>{};
  for (final arg in args) {
    final match = RegExp(r'^--([a-z-]+)=(.*)$').firstMatch(arg);
    if (match == null) _fail('unexpected argument $arg');
    values[match[1]!] = match[2]!;
  }
  String required(String name) => values[name] ?? _fail('--$name is required');
  final unknown = values.keys.where(
    (k) => !const {'hitmaps', 'sources', 'output'}.contains(k),
  );
  if (unknown.isNotEmpty) _fail('unexpected argument --${unknown.first}');
  final hitmaps = required('hitmaps');
  final sources = required('sources');
  final output = required('output');
  final manifest = Platform.environment['COVERAGE_MANIFEST'];
  if (manifest == null) {
    _fail('COVERAGE_MANIFEST is not set; run under `bazel coverage`');
  }
  final directory = Directory(hitmaps);
  final hits = directory.existsSync()
      ? await HitMap.parseFiles(
          directory
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json')),
        )
      : <String, HitMap>{};
  final names = readSourcesFile(sources);
  final String report;
  try {
    report = lcov(
      hits,
      CoverageSources(
        instrumented: File(manifest).readAsLinesSync(),
        packages: names.packages,
        files: names.files,
        locate: Runfiles.create().rlocation,
      ),
    );
  } on FormatException catch (e) {
    // An unbalanced `coverage:ignore-start`/`-end` in a source.
    stderr.writeln('coverage_converter: ${e.message}');
    exit(1);
  }
  writeTracefile(output, report);
}

Never _fail(String message) {
  stderr.writeln('coverage_converter: $message');
  exit(2);
}
