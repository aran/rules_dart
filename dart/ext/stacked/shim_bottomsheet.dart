import 'package:rules_dart_ext/worker_entry.dart';
import 'package:stacked_generator/builder.dart' show stackedBottomsheetGenerator;

Future<void> main(List<String> args) => shimMain(args, stackedBottomsheetGenerator);
