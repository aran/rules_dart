import 'dart:io';

/// The greeting a fixture holds, read by its path from the package root, as
/// a test run by `dart test` can.
String greetingFrom(String fixture) =>
    File('test/fixtures/$fixture').readAsStringSync().trim();
