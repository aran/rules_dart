/// drift_dev preparing-stage shim. Reads .drift / .moor files; emits
/// .drift_prep.json + .expr.temp.dart per source.
import 'package:drift_dev/integrations/build.dart' show preparingBuilder;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, preparingBuilder);
