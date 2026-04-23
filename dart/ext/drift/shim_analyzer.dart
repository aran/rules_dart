/// drift_dev analyzer-stage shim. Combines parsed .drift schemas with
/// @DriftDatabase metadata; emits .drift_elements.json + .drift_module.json.
import 'package:drift_dev/integrations/build.dart' show analyzer;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, analyzer);
