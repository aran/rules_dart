/// `analyzer_errors <sdk> <file>`: resolves the file with `package:analyzer`
/// against the SDK at the given path, as a code generator does, and prints
/// its diagnostics. Exits non-zero when there are any, or none could be had.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  // The analyzer takes only absolute, normalized paths: on Windows, `\` alone
  // as the separator.
  final sdk = p.normalize(p.absolute(args[0]));
  final file = p.normalize(p.absolute(args[1]));
  final contexts = AnalysisContextCollection(
    includedPaths: [file],
    sdkPath: sdk,
  );
  final result = await contexts.contextFor(file).currentSession.getErrors(file);
  if (result is! ErrorsResult) {
    stderr.writeln('no diagnostics for $file: $result');
    exit(2);
  }
  for (final d in result.diagnostics) {
    stderr.writeln(d);
  }
  await contexts.dispose();
  exit(result.diagnostics.isEmpty ? 0 : 1);
}
