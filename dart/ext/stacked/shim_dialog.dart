import 'package:rules_dart_ext/worker_entry.dart';
import 'package:stacked_generator/builder.dart' show stackedDialogGenerator;

Future<void> main(List<String> args) => shimMain(args, stackedDialogGenerator);
