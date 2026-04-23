import 'package:copy_with_extension_gen/copy_with_extension_gen.dart' show copyWith;
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, copyWith);
