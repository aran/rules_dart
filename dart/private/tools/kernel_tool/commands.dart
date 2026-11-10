import 'dart:io';

import 'args.dart';
import 'check_command.dart';
import 'digest_command.dart';
import 'entry_command.dart';
import 'frontend_command.dart';
import 'link_command.dart';
import 'module_command.dart';
import 'worker_command.dart';

// The steps of a modular test build and of the whole-program compile, driven
// from one binary so that Windows needs no shell:
//
//   module    one library target to kernel modules, with `kernel_worker`, and
//             a manifest saying what each holds and whether it can be used
//   check     what a target's files import against what it depends on, with no
//             compiler, so that a library nothing compiles is checked too
//   entry     a test's main file to a kernel file, with `frontend_server`,
//             against the modules its imports reach
//   link      those modules and the entry joined into one file the VM can run
//   frontend  an executable's whole program to a kernel file, with
//             `frontend_server`, whose protocol output it keeps out of the
//             build log
//   digest    a file's SHA-256, which names the cached snapshot of the
//             `package:test` runner the file is
//
// Each takes `@paramsfile`, one argument per line, or the arguments directly.
// `module` also runs as a Bazel persistent worker (`worker_command.dart`).
Future<int> runKernelTool(List<String> argv) async {
  if (argv.contains('--persistent_worker')) return runWorker(argv);
  if (argv.isEmpty || !isCommand(argv.first)) {
    stderr.writeln(
      'usage: kernel_tool <module|check|entry|frontend|link|digest> @paramsfile',
    );
    return 64;
  }
  final command = argv.first;
  try {
    final args = Args.parse(command, Args.expand(argv.skip(1)));
    switch (command) {
      case 'module':
        return await runModule(args, err: stderr);
      case 'check':
        return await runCheck(args, err: stderr);
      case 'entry':
        return await runEntry(args);
      case 'frontend':
        return await runFrontend(args);
      case 'digest':
        return await runDigest(args);
      default:
        return await runLink(args);
    }
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  }
}
