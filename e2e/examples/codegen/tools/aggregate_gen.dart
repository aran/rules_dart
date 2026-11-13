import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:rules_dart_ext/worker_entry.dart';

/// Aggregate-stage generator: records the asset path of the primary input and
/// of every shard the aggregate sees, with each shard's content. Lets tests
/// assert that generated inputs reaching `dart_aggregate_codegen` carry
/// correct in-package asset paths even when the codegen targets live in a
/// different Bazel package than the Dart package root.
Future<void> main(List<String> args) =>
    shimMain(args, (_) => _AggregateBuilder());

class _AggregateBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.agg.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final buf = StringBuffer()
      ..writeln('// input-asset: ${buildStep.inputId.path}');
    final shards = await buildStep
        .findAssets(Glob('lib/**.shard.json'))
        .toList();
    shards.sort((a, b) => a.path.compareTo(b.path));
    for (final shard in shards) {
      final content = await buildStep.readAsString(shard);
      buf
        ..writeln('// extra-asset: ${shard.path}')
        ..writeln('// extra-content: ${content.trim()}');
    }
    for (final output in buildStep.allowedOutputs) {
      await buildStep.writeAsString(output, buf.toString());
    }
  }
}
