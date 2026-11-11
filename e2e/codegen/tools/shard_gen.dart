import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

/// Emits a one-line metadata shard for its input: the stand-in for a per-file
/// metadata stage (e.g. `.metadata.json` shards).
Future<void> main(List<String> args) => shimMain(args, (_) => _ShardBuilder());

class _ShardBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.shard.json'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final base = buildStep.inputId.pathSegments.last;
    for (final output in buildStep.allowedOutputs) {
      await buildStep.writeAsString(output, 'shard-for:$base\n');
    }
  }
}
