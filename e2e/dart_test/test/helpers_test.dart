import '../test_helpers.dart';

void main() {
  expectEquals(1 + 1, 2, 'basic addition');
  expectEquals('hello'.length, 5, 'string length');

  bool threw = false;
  try {
    expectEquals(1, 2, 'should fail');
  } on AssertionError {
    threw = true;
  }
  expectEquals(threw, true, 'expectEquals should throw on mismatch');

  print('All helpers tests passed!');
}
