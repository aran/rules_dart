/// Structural test for `shim_bottomsheet` — reads the generated
/// `app.bottomsheets.dart` via runfiles.

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late String generated;

  setUpAll(() {
    final r = Runfiles.create();
    generated =
        File(r.rlocation('_main/stacked/lib/app.bottomsheets.dart'))
            .readAsStringSync();
  });

  test('emits the StackedBottomsheetGenerator header + stacked imports', () {
    expect(generated, contains('GENERATED CODE - DO NOT MODIFY'));
    expect(
        generated,
        anyOf(
          contains('StackedBottomsheetGenerator'),
          contains('BottomSheetsGenerator'),
        ));
    expect(generated, contains("import 'package:stacked_services/stacked_services.dart'"));
  });

  test('references ConfirmSheet and sets up a BottomSheetService registrar',
      () {
    expect(generated, contains('ConfirmSheet'));
    expect(
        generated,
        anyOf(
          contains('setupBottomSheetUi'),
          contains('BottomSheetType'),
          contains('BottomSheetRegistrar'),
        ));
  });
}
