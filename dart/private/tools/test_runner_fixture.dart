import 'dart:convert';
import 'dart:io';

/// Stands in for a compiled test `main` under `test_runner_test.dart`.
///
/// - `stream`: announces itself on stdout and stderr, then echoes one line of
///   stdin. The driver sends that line only once it has seen both
///   announcements, so the echo proves they arrived while this was running.
/// - `leak <release>`: starts a copy of itself in `linger` mode that shares
///   this process's stdio, then exits without waiting for it.
/// - `linger <release>`: holds that stdio open until `<release>` exists.
Future<void> main(List<String> args) async {
  switch (args) {
    case ['stream']:
      stdout.writeln('stdout-ready');
      stderr.writeln('stderr-ready');
      final line = await stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      stdout.writeln('echo:$line');
    case ['leak', final release]:
      await Process.start(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        'linger',
        release,
      ], mode: ProcessStartMode.inheritStdio);
      exit(0);
    case ['linger', final release]:
      while (!File(release).existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    default:
      stderr.writeln('usage: stream | leak <release> | linger <release>');
      exit(2);
  }
}
