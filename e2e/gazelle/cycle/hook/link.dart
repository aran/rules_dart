// The package's link hook, which `dart_link_hook` would run: the library of
// lib/ states it, and its imports are that library's dependencies.
import 'package:cycle/cycle.dart';

void main(List<String> args) => print(greeting);
