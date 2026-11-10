// Command lines of the summary analyzer, and what every command answers.
import 'dart:io';

import 'package:path/path.dart' as p;

/// What a command reports, and its exit code.
typedef Result = ({int exitCode, String output});

/// How to analyze without summaries, closing every refusal.
const turnOff =
    'Analysis against summaries uses analyzer internals the Dart SDK does not '
    'support. To analyze every dependency from its source instead, build with '
    '--@rules_dart//dart:analysis_summaries=false.\n';

/// A malformed command line: exit 64, as `sysexits.h` has it.
Result usage(String problem) =>
    (exitCode: 64, output: 'summary_analyzer: $problem\n');

/// A bad argument.
class ArgsException implements Exception {
  ArgsException(this.message);
  final String message;
}

/// A command's `--name value` options and its `--flag`s.
class Args {
  Args._(this._values, this._flags);

  static const _flagNames = {'fatal-infos'};

  /// The options of [args], each value a path made absolute against the
  /// current directory.
  factory Args.parse(Iterable<String> args) {
    final values = <String, List<String>>{};
    final flags = <String>{};
    final list = args.toList();
    for (var i = 0; i < list.length; i++) {
      final arg = list[i];
      if (!arg.startsWith('--')) throw ArgsException('unexpected `$arg`');
      final name = arg.substring(2);
      if (_flagNames.contains(name)) {
        flags.add(name);
        continue;
      }
      if (++i == list.length) throw ArgsException('`$arg` needs a value');
      final value = list[i];
      values.putIfAbsent(name, () => []).add(p.normalize(p.absolute(value)));
    }
    return Args._(values, flags);
  }

  final Map<String, List<String>> _values;
  final Set<String> _flags;

  /// The one value of `--name`.
  String one(String name) {
    final values = _values[name];
    if (values == null || values.length != 1) {
      throw ArgsException('give `--$name` exactly once');
    }
    return values.single;
  }

  /// Every value of `--name`, in order.
  List<String> all(String name) => _values[name] ?? const [];

  bool flag(String name) => _flags.contains(name);
}

/// [args] with each `@file` replaced by the file's lines.
List<String> expandFlagfiles(List<String> args) => [
  for (final arg in args)
    if (arg.startsWith('@'))
      ...File(arg.substring(1)).readAsLinesSync().where((l) => l.isNotEmpty)
    else
      arg,
];
