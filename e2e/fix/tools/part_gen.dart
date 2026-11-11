// Stands in for a real builder (freezed, json_serializable, …).
//
// Which builder produced a file is irrelevant to the fixes: eligibility is
// decided from `File.is_source`, so all that matters here is that Bazel records
// the output as generated. What the generated code contains does matter — the
// hand-written library resolves `ModelBase` and `modelLabel` out of these parts
// while the fix rule has them excluded.
//
// Options: `violation` (bool) writes the parts with a lint `dart fix` rewrites.
import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(
  args,
  (options) => _PartBuilder(violation: options.config['violation'] == true),
);

class _PartBuilder implements Builder {
  _PartBuilder({required this.violation});

  final bool violation;

  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart', '.freezed.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = buildStep.inputId.pathSegments.last;
    // `prefer_final_locals` fires on `var`, so one keyword is the whole
    // difference between a part `dart fix` wants to rewrite and one it does
    // not.
    final keyword = violation ? 'var' : 'final';
    for (final output in buildStep.allowedOutputs) {
      final body = output.path.endsWith('.g.dart')
          ? '''
abstract class ModelBase {
  String describe();

  String tag() {
    $keyword value = 'g';
    return value;
  }
}
'''
          : '''
String modelLabel() {
  $keyword label = 'generated';
  return label;
}
''';
      await buildStep.writeAsString(output, '''
// GENERATED CODE - DO NOT MODIFY BY HAND
part of '$input';

$body''');
    }
  }
}
