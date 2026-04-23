import 'package:json_serializable/builder.dart' show jsonSerializable;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, jsonSerializable);
