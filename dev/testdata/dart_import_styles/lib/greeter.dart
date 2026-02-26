import 'dart:async';

import 'helper.dart';

Future<String> greet(String name) async {
  return format('Hello, $name!');
}
