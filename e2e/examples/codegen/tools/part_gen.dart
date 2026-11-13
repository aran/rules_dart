import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

/// Emits a `part of` companion of its input defining `generatedMessage()`.
Future<void> main(List<String> args) => shimMain(args, (_) => _PartBuilder());

class _PartBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final libName = buildStep.inputId.pathSegments.last;
    for (final output in buildStep.allowedOutputs) {
      await buildStep.writeAsString(output, '''
// GENERATED CODE - DO NOT MODIFY BY HAND
part of '$libName';

String generatedMessage() => 'generated part works';
''');
    }
  }
}
