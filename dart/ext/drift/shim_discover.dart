/// drift_dev discover-stage shim. Picks up @DriftDatabase / @DriftAccessor
/// annotations and stages them for the analyzer phase.
import 'package:drift_dev/integrations/build.dart' show discover;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, discover);
