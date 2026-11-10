import 'dart:io';

import 'package:working_dir/fixture.dart';

void main() {
  final here = Directory.current.uri.pathSegments.where((s) => s.isNotEmpty);
  if (here.last != 'working_dir') {
    throw StateError('runs in ${Directory.current.path}, not working_dir/');
  }
  if (!File('test/working_dir_test.dart').existsSync()) {
    throw StateError('test/working_dir_test.dart is not where the test runs');
  }
  final greeting = readFixture('greeting.txt');
  if (greeting != 'hello from the package root') {
    throw StateError('read "$greeting"');
  }
}
