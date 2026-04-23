import 'package:built_value_generator/builder.dart' show builtValue;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, builtValue);
