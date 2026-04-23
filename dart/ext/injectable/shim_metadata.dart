/// injectable_generator stage 1: per-class metadata. Runs
/// `injectableBuilder` (LibraryBuilder) over a single annotated `.dart`
/// source and emits `<src>.injectable.json` describing every
/// `@injectable`/`@singleton`/etc. it finds.
///
/// Sources with no injectable annotations produce no Builder output.
/// Bazel still expects the declared `.injectable.json` to exist and the
/// downstream config stage's `jsonDecode` needs valid JSON — supply `[]`
/// (empty array) via the shim's `emptyOutput` hook.
import 'dart:convert';

import 'package:injectable_generator/builder.dart' show injectableBuilder;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(
      args,
      injectableBuilder,
      emptyOutput: (_, _) => utf8.encode('[]'),
    );
