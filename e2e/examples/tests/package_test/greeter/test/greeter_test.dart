@TestOn('vm')
library;

import 'dart:io';

import 'package:greeter/greeter.dart';
import 'package:test/test.dart';

void main() {
  test('runs in the package root', () {
    expect(
      Directory.current.uri.pathSegments.where((s) => s.isNotEmpty).last,
      'greeter',
    );
    expect(
      File('pubspec.yaml').existsSync(),
      isFalse,
      reason: 'only `data` is in runfiles',
    );
    expect(File('dart_test.yaml').existsSync(), isTrue);
    expect(File('test/greeter_test.dart').existsSync(), isTrue);
  });

  test('reads a fixture by its path from the package root', () {
    expect(greetingFrom('greeting.txt'), 'hello from greeter');
  });
}
