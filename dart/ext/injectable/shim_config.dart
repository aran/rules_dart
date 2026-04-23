/// injectable_generator stage 2: assembled DI config. Runs
/// `injectableConfigBuilder` (LibraryBuilder) over the source declaring
/// `@InjectableInit`. The builder reads every `<class>.injectable.json`
/// file the package emitted in stage 1 (visible via `--dep`) and emits
/// `<src>.config.dart` plus a `.module.dart` shard for any module classes.
import 'package:injectable_generator/builder.dart' show injectableConfigBuilder;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, injectableConfigBuilder);
