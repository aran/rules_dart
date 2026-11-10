// `sdk-summary` and `summarize`: the summaries analysis reads in place of
// source.
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/sdk/build_sdk_summary.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/summary2/package_bundle_format.dart';
import 'package:path/path.dart' as p;

import 'args.dart';
import 'context.dart';

/// Writes the summary of the SDK at `--sdk` to `--out`, with the libraries
/// an `--embedder` (a package's `lib/_embedder.yaml`, as Flutter's
/// `sky_engine` has for `dart:ui`) adds to it.
Future<Result> sdkSummary(Args args) async {
  final sdk = args.one('sdk');
  final mismatch = sdkMismatch(sdk, _version(sdk));
  if (mismatch != null) return (exitCode: 1, output: mismatch);
  final bytes = await buildSdkSummary(
    resourceProvider: PhysicalResourceProvider.INSTANCE,
    sdkPath: sdk,
    embedderYamlPath: args.all('embedder').singleOrNull,
  );
  File(args.one('out')).writeAsBytesSync(bytes);
  return (exitCode: 0, output: '');
}

String _version(String sdk) =>
    File(p.join(sdk, 'version')).readAsStringSync().trim();

/// Writes the summary of the libraries among `--file`s (files, or
/// directories of them) that have a `package:` URI to `--out`.
///
/// Everything they import from another target comes from a `--summary`. A
/// file with no `package:` URI (one outside a package's `lib/`) cannot be
/// imported by another target, so no summary needs it. A part is summarized
/// as a unit of the library that includes it, as the analyzer resolved that
/// library; a part no library includes (a generator's `.g.dart` beside a
/// source with nothing to generate) belongs to no library and is in no
/// summary. The bundle must hold every library it was given, with each of its
/// units: the analyzer writes a bundle without a library it could not load,
/// and silently, which would leave every dependent unable to resolve it.
Future<Result> summarize(Args args) async {
  final project = args.one('project');
  final collection = newCollection(args);
  try {
    final context = collection.contexts.single;
    final session = context.currentSession;
    final libraries = <String>[];
    final units = <String>{};
    final files = <String>[
      for (final given in args.all('file'))
        if (Directory(given).existsSync())
          for (final f in Directory(given).listSync(recursive: true))
            if (f is File && f.path.endsWith('.dart')) p.normalize(f.path),
      for (final given in args.all('file'))
        if (given.endsWith('.dart') && File(given).existsSync()) given,
    ]..sort();
    for (final path in files) {
      final uri = session.uriConverter.pathToUri(path);
      if (uri == null || !uri.isScheme('package')) continue;
      switch (await session.getLibraryByUri('$uri')) {
        case LibraryElementResult(:final element):
          libraries.add('$uri');
          units.addAll([for (final f in element.fragments) '${f.source.uri}']);
        case NotLibraryButPartResult():
          // Expected through the library that includes it, if one does.
          break;
        case final other:
          return (
            exitCode: 1,
            output:
                'summary_analyzer: cannot summarize $uri ($path): '
                '${other.runtimeType}.\n$turnOff',
          );
      }
    }
    final bytes = await context.driver.buildPackageBundle(
      uriList: [for (final l in libraries) Uri.parse(l)],
    );
    final bundled = PackageBundleReader(bytes).libraries;
    final written = {for (final l in bundled) l.uriStr};
    final writtenUnits = {
      for (final l in bundled)
        for (final u in l.units) u.uriStr,
    };
    final missing = [
      ...libraries.where((l) => !written.contains(l)),
      ...units.where((u) => !writtenUnits.contains(u)),
    ];
    if (missing.isNotEmpty) {
      return (
        exitCode: 1,
        output:
            'summary_analyzer: the summary of $project lacks '
            '${missing.join(', ')}, which the analyzer did not write.\n'
            '$turnOff',
      );
    }
    File(args.one('out')).writeAsBytesSync(bytes);
    return (exitCode: 0, output: '');
  } finally {
    // A failure to dispose fails the request: in a worker, the next request
    // runs in the same process.
    await collection.dispose();
  }
}
