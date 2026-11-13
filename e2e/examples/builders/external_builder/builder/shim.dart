import 'package:greeting_builder/greeting_builder.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, greetingBuilder);
