import 'package:freezed/builder.dart' show freezed;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, freezed);
