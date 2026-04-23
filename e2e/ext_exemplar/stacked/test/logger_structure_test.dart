/// Structural test for `shim_logger` — reads the generated
/// `app.logger.dart` via runfiles and asserts the logger factory +
/// helper function emission.
///
/// `StackedLogger(logHelperName: 'getFixtureLogger')` customises the
/// top-level helper name so the default ('getLogger') wouldn't match.
/// Asserting the custom name proves the shim plumbed the annotation
/// parameters through to the builder.

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late String generated;

  setUpAll(() {
    final r = Runfiles.create();
    generated = File(r.rlocation('_main/stacked/lib/app.logger.dart'))
        .readAsStringSync();
  });

  test('emits the StackedLoggerGenerator header + logger imports', () {
    expect(generated, contains('GENERATED CODE - DO NOT MODIFY'));
    expect(
        generated,
        anyOf(
          contains('StackedLoggerGenerator'),
          contains('LoggerGenerator'),
        ));
    expect(generated, contains("import 'package:logger/logger.dart'"));
  });

  test('emits the custom logHelperName (getFixtureLogger)', () {
    // The annotation overrides the default 'getLogger' → 'getFixtureLogger'.
    // A regression in annotation-parameter propagation would flip this.
    expect(generated, contains('getFixtureLogger'));
    expect(
        generated.contains('getLogger'),
        isFalse,
        reason: 'default helper name should not be emitted when overridden');
  });

  test('wires a PrettyPrinter and top-level log class', () {
    // stacked_logger_generator consistently emits a `PrettyPrinter(...)`
    // configuration and a top-level logger class the helper returns.
    expect(generated, contains('PrettyPrinter'));
    expect(generated, contains('Logger'));
  });
}
