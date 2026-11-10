// The analysis context every command builds: one staged project, read against
// the SDK and the dependencies' summaries.
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/experiments.dart';

import 'package:path/path.dart' as p;

import 'args.dart';

/// A fresh context collection over `--project`, with `--sdk-summary` and
/// every `--summary`, and `--options` for every file when given.
///
/// The SDK is read from its summary alone, which holds everything the
/// analyzer reads of it (its libraries, its version, its allowed
/// experiments), so no file of the SDK is an input. Nothing is cached across
/// collections: a worker's requests share no state but the code.
AnalysisContextCollectionImpl newCollection(Args args) =>
    AnalysisContextCollectionImpl(
      includedPaths: [args.one('project')],
      optionsFile: args.all('options').singleOrNull,
      sdkPath: p.dirname(args.one('sdk-summary')),
      sdkSummaryPath: args.one('sdk-summary'),
      librarySummaryPaths: args.all('summary'),
      byteStore: MemoryByteStore(),
      resourceProvider: PhysicalResourceProvider.INSTANCE,
    );

/// Why this analyzer cannot analyze for the SDK at [sdk] whose `version` file
/// says [sdkVersion], or null when it can.
///
/// The toolchain pairs the analyzer with its SDK by release; this catches a
/// pairing gone wrong (a checkout of another release) before it gives answers
/// that differ from `dart analyze`.
String? sdkMismatch(String sdk, String sdkVersion) {
  final language = ExperimentStatus.currentVersion;
  final parts = sdkVersion.split('.');
  if (parts.length < 2 ||
      parts[0] != '${language.major}' ||
      parts[1] != '${language.minor}') {
    return 'summary_analyzer: this analyzer is built from the source of '
        'Dart ${language.major}.${language.minor}, but the SDK at $sdk is '
        '$sdkVersion. Register the analyzer toolchain of that SDK '
        '(`dart_analyzer_toolchain`).\n$turnOff';
  }
  return null;
}
