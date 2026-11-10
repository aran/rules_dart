/// `analyzer_errors <sdk> <file>`: resolves the file with `package:analyzer`
/// against the SDK at the given path, as a code generator does, and prints
/// its diagnostics. Exits non-zero when there are any, or none could be had.
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';

Future<void> main(List<String> args) async {
  final sdk = Directory(args[0]).absolute.path;
  final file = File(args[1]).absolute.path;
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
