/// The app's one message.
library;

import 'dart:convert';

import 'package:app/src/model.dart';
import 'package:greet/greet.dart';

/// The line every binary prints: a greeting and its visitor as JSON.
String message() {
  final visitor = Visitor.fromJson({'name': 'Bazel', 'visits': 3});
  return '${greet(visitor.name)} ${jsonEncode(visitor.toJson())}';
}
