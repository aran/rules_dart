import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

/// Emits one compiler's variant of `package:i64`'s generated part, the one its
/// `variant` option names.
///
/// A generator cannot see the web compiler (codegen is built once, for every
/// compiler), so it is run once per variant, each in its own package, and the
/// library using them picks one with a `select()`.
Future<void> main(List<String> args) => shimMain(
  args,
  (options) => _VariantBuilder(options.config['variant'] as String),
);

class _VariantBuilder implements Builder {
  _VariantBuilder(this.variant);

  final String variant;

  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final type = variant == 'js' ? 'List<int>' : 'Int64List';
    final make = variant == 'js'
        ? 'List<int>.filled(length, 0)'
        : 'Int64List(length)';
    for (final output in buildStep.allowedOutputs) {
      await buildStep.writeAsString(output, '''
// GENERATED CODE - DO NOT MODIFY BY HAND
part of 'i64.dart';

/// The variant this program was built with.
const String variant = 'i64 variant $variant';

/// A list of 64-bit integers, as this compiler represents one.
typedef I64List = $type;

/// A zeroed [I64List] of [length] elements.
I64List makeI64List(int length) => $make;
''');
    }
  }
}
