/// End-to-end test for `shim_form` / `stacked_form_library`.
///
/// The generated `.form.dart` requires Flutter at runtime, so we can't
/// instantiate `TextEditingController` or `FormViewModel` here. We can
/// still exercise the full shim pipeline (dart_codegen → shim_form →
/// stackedFormGenerator → output file) and validate its emitted
/// structure — the same approach `stacked_generator`'s own
/// `form_builder_test.dart` uses for its 495-line internal test suite.
///
/// Every assertion below is load-bearing: an off-by-one in field
/// iteration, a dropped annotation config, a shim-side config-passing
/// regression, or a broken ResourceManager would drop a field's
/// constants / controller / value getter and flip one of these checks.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late String generatedSource;

  setUpAll(() {
    final r = Runfiles.create();
    final path = r.rlocation('_main/stacked/lib/login_view.form.dart');
    generatedSource = File(path).readAsStringSync();
  });

  group('shim_form (stackedFormGenerator) end-to-end output', () {
    test('emits the header + standard imports package:build expects', () {
      expect(generatedSource, startsWith('// GENERATED CODE - DO NOT MODIFY BY HAND'));
      expect(generatedSource, contains("import 'package:flutter/material.dart'"));
      expect(generatedSource, contains("import 'package:stacked/stacked.dart'"));
    });

    test('emits one ValueKey constant per field, verbatim', () {
      // stacked_form_content_generator's addValueMapKeys. If the shim
      // dropped a field, the corresponding constant would be missing.
      expect(generatedSource, contains("String EmailValueKey = 'email'"));
      expect(generatedSource, contains("String PasswordValueKey = 'password'"));
      expect(generatedSource, contains("String BirthdayValueKey = 'birthday'"));
      expect(generatedSource, contains("String CountryValueKey = 'country'"));
    });

    test('emits a value-to-title map for FormDropdownField entries only', () {
      // CountryValueToTitleMap must include both static items (preserves
      // the @FormView(items: ...) contents through the shim's
      // annotation-constant resolution). Non-dropdown fields must NOT
      // produce a corresponding map.
      expect(generatedSource, contains('CountryValueToTitleMap'));
      expect(generatedSource, contains("'us': 'United States'"));
      expect(generatedSource, contains("'ca': 'Canada'"));
      expect(generatedSource, isNot(contains('EmailValueToTitleMap')));
      expect(generatedSource, isNot(contains('BirthdayValueToTitleMap')));
    });

    test('emits a TextEditingController getter only for FormTextField names',
        () {
      // addTextEditingControllersForTextFields generates one getter per
      // text field — and only for text fields. A FormDropdownField /
      // FormDateField must not produce a controller getter.
      expect(generatedSource,
          contains('TextEditingController get emailController'));
      expect(generatedSource,
          contains('TextEditingController get passwordController'));
      expect(generatedSource,
          isNot(contains('TextEditingController get birthdayController')));
      expect(generatedSource,
          isNot(contains('TextEditingController get countryController')));
    });

    test('emits a FocusNode getter per text field', () {
      expect(generatedSource, contains('FocusNode get emailFocusNode'));
      expect(generatedSource, contains('FocusNode get passwordFocusNode'));
    });

    test('emits a mixin bound to the annotated class name', () {
      // The mixin name is derived from the annotated class (LoginView).
      // If the shim's element resolution broke, it would either throw
      // or use the wrong name.
      expect(generatedSource, contains(RegExp(r'mixin\s+\$LoginView\b')));
    });

    test(
        'emits a ValueProperties extension with a typed value getter per field',
        () {
      // One getter per @FormView field. Return type is derived from the
      // field kind: text → String?, date → DateTime?, dropdown → String?.
      // A regression in kind→type mapping would surface as a wrong type.
      expect(generatedSource,
          contains('extension ValueProperties on FormStateHelper'));
      expect(generatedSource, contains('String? get emailValue'));
      expect(generatedSource, contains('String? get passwordValue'));
      expect(generatedSource, contains('DateTime? get birthdayValue'));
      expect(generatedSource, contains('String? get countryValue'));
    });

    test('emits hasX / setXValidationMessage helpers per field', () {
      // Proves the generator walked every field in the annotation
      // (not just the first one) through the helpers' emit pass.
      for (final field in const ['Email', 'Password', 'Birthday', 'Country']) {
        expect(generatedSource, contains('bool get has$field'),
            reason: 'missing has$field getter');
        expect(
            generatedSource, contains('set${field}ValidationMessage'),
            reason: 'missing set${field}ValidationMessage setter');
      }
    });

    test('emits a Methods extension with kind-specific actions per field', () {
      // DateField → selectBirthday (awaits showDatePicker).
      // DropdownField → setCountry (writes the selected value).
      // Proves FormDateField / FormDropdownField are each routed to their
      // dedicated emitter (text fields have no entry here).
      expect(generatedSource, contains('extension Methods on FormStateHelper'));
      expect(generatedSource, contains('Future<void> selectBirthday'));
      expect(generatedSource, contains('void setCountry(String country)'));
      expect(generatedSource, isNot(contains('void setEmail(String ')));
    });

    test('emits the form-update listeners referenced by the mixin', () {
      // stacked_generator 2.0.2 deprecated `listenToFormUpdated` in
      // favour of `syncFormWithViewModel`, but still emits both. Both
      // signal the mixin properly registered addListener hooks —
      // regression in either would indicate the sub-builder was swapped
      // or its config dropped.
      expect(generatedSource, contains('syncFormWithViewModel'));
      expect(generatedSource, contains('listenToFormUpdated'));
      expect(generatedSource, contains('emailController.addListener'));
      expect(generatedSource, contains('passwordController.addListener'));
    });

    test('emits a disposeForm that clears both controllers and focus nodes',
        () {
      expect(generatedSource, contains('void disposeForm()'));
      expect(generatedSource,
          contains('_LoginViewTextEditingControllers.clear()'));
      expect(generatedSource, contains('_LoginViewFocusNodes.clear()'));
    });
  });
}
