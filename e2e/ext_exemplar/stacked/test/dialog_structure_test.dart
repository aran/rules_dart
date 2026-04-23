/// Structural test for `shim_dialog` — reads the generated
/// `app.dialogs.dart` via runfiles and asserts it contains the
/// DialogService scaffolding for each `StackedDialog(classType: ...)`
/// registration.

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late String generated;

  setUpAll(() {
    final r = Runfiles.create();
    generated = File(r.rlocation('_main/stacked/lib/app.dialogs.dart'))
        .readAsStringSync();
  });

  test('emits the StackedDialogGenerator header + Flutter + stacked imports',
      () {
    expect(generated, contains('GENERATED CODE - DO NOT MODIFY'));
    expect(
        generated,
        anyOf(
          contains('StackedDialogGenerator'),
          contains('DialogsGenerator'),
        ));
    expect(generated, contains("import 'package:stacked_services/stacked_services.dart'"));
  });

  test('references InfoDialog by name and sets up a DialogService registrar',
      () {
    expect(generated, contains('InfoDialog'));
    // stacked generates a `DialogType` enum (or similar) with one entry
    // per registered dialog, plus a `setupDialogUi` / `DialogRegistrar`
    // entry point that walks the registrations.
    expect(
        generated,
        anyOf(
          contains('setupDialogUi'),
          contains('DialogType'),
          contains('DialogRegistrar'),
        ));
  });
}
