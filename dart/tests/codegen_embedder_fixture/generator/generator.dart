/// Writes each field of each class the input declares as
/// `<class>.<field>: <type> from <library of the type>`, one per line: a type
/// the generator cannot resolve reads `InvalidType`.
library;

import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, (_) => _FieldTypes());

class _FieldTypes implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.types.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final library = await buildStep.inputLibrary;
    final lines = [
      for (final type in library.classes)
        for (final field in type.fields)
          '${type.name}.${field.name}: ${field.type.getDisplayString()} '
              'from ${field.type.element?.library?.uri}',
    ];
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      '${lines.join('\n')}\n',
    );
  }
}
