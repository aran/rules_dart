import 'package:mockito/src/builder.dart' show buildMocks;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, buildMocks);
