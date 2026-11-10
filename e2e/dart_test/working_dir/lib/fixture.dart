import 'dart:io';

/// Reads a fixture by its path from the package root, as a test run by
/// `dart test` can.
String readFixture(String name) =>
    File('test/fixtures/$name').readAsStringSync().trim();
