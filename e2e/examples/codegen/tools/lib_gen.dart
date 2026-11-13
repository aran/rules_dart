import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

/// Emits a standalone library (not a `part`) defining `generatedValue()`,
/// consumed via `import` (relative or `package:`).
Future<void> main(List<String> args) => shimMain(args, (_) => _LibBuilder());

class _LibBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.lib.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    for (final output in buildStep.allowedOutputs) {
      await buildStep.writeAsString(output, '''
// GENERATED CODE - DO NOT MODIFY BY HAND
String generatedValue() => 'generated lib works';
''');
    }
  }
}
