import 'dart:io';

import 'args.dart';
import 'compile.dart';

/// `frontend`: one `frontend_server` compile of a whole program, with the
/// server's protocol consumed rather than shown.
///
/// What follows `--` is the runtime's command line, the server's snapshot
/// first. The server always answers on stdout with a result line, a bare
/// identifier, and the identifier again with the output path and an error
/// count, and Bazel shows the output of every action that succeeds. Here that
/// is read, and only the compiler's own messages (errors, warnings) are
/// written to stderr, so a clean compile prints nothing and a failed one shows
/// what a user can act on. The count, not the exit status, says whether it
/// failed; a server that never reported a result has crashed.
Future<int> runFrontend(Args args, {StringSink? err}) async {
  err ??= stderr;
  if (args.rest.isEmpty) {
    throw const UsageException(
      'kernel_tool frontend: the compiler command line follows --',
    );
  }
  final result = await runProcess(args.one('runtime'), args.rest);
  final server = FrontendServerOutput.parse(result.output);
  err.write(server.diagnostics);
  if (result.exitCode == 0 && server.errorCount == 0) return 0;
  if (server.errorCount == null && result.exitCode == 0) {
    err.writeln('frontend_server did not report a result');
  }
  return 1;
}
