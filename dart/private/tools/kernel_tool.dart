// Build-action driver for modular test builds: compiles a library target to
// kernel modules, a test's entrypoint against the modules it reaches, and links
// them.
//
// One binary rather than three so the actions run unchanged on Windows, and so
// the checks that must happen between compiler runs (strict deps, which modules
// a program reaches, a library defined by two targets) live in Dart beside the
// file handling they need. See `kernel_tool/commands.dart`.
import 'dart:io';

import 'kernel_tool/commands.dart';

Future<void> main(List<String> args) async {
  exit(await runKernelTool(args));
}
