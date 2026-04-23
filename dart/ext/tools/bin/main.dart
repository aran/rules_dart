import 'dart:io';

import 'package:rules_dart_check_dual_build_collisions/check_dual_build_collisions.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
