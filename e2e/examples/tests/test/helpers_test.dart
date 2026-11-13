import 'dart:io';

import '../test_helpers.dart';

void main() {
  expectEquals(1 + 1, 2, 'basic addition');
  expectEquals('hello'.length, 5, 'string length');

  // Caught as `Object` and narrowed after the fact: an `on AssertionError`
  // clause would trip `avoid_catching_errors`, and any other throw leaves
  // `threw` false, which the check below reports.
  var threw = false;
  try {
    expectEquals(1, 2, 'should fail');
  } on Object catch (e) {
    threw = e is AssertionError;
  }
  expectEquals(threw, true, 'expectEquals should throw on mismatch');

  stdout.writeln('All helpers tests passed!');
}
