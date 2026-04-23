/// drift_dev generation-stage shim. Runs all three drift_dev factories
/// (discover → analyzer → driftBuilder) in sequence, each as a separate
/// Builder over the same BuildStep — so each gets its own
/// `allowedOutputs.single` correctly, and intermediate JSON artifacts
/// from discover and analyzer stay visible to driftBuilder via
/// `findAssets`.
///
/// Mirrors the upstream `drift_dev` builder's `builder_factories: [discover,
/// analyzer, driftBuilder]` shape — build_runner loads all three under one
/// builder name and runs them in order sharing state; we do the same here.
library;

import 'package:drift_dev/integrations/build.dart'
    show analyzer, discover, driftBuilder;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) =>
    shimMain(args, [discover, analyzer, driftBuilder]);
