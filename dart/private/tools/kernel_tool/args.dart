import 'dart:convert';
import 'dart:io';

import 'manifest.dart';

const _optionsByCommand = {
  'module': {
    'runtime', 'snapshot', 'label', 'platform', 'target', 'libraries-spec',
    'libraries-target', 'package-config', 'multi-root', 'src', 'dep-modules',
    'dep-manifest', 'define', 'output-dir', 'manifest-output', 'package-name',
    'lib-root', 'available-package', 'direct-package', //
  },
  'entry': {
    'runtime', 'snapshot', 'sdk-root', 'label', 'platform', 'target',
    'package-config', 'multi-root', 'dep-modules', 'dep-manifest', 'define',
    'native-assets', 'main', 'output', 'selection-output', //
  },
  'link': {'label', 'entry', 'selection', 'dep-manifest', 'output'},
};

/// Options that stand alone, without a value.
const _flagsByCommand = {
  'module': {'check-layering', 'tolerate-policy'},
};

bool isCommand(String name) => _optionsByCommand.containsKey(name);

/// The command line is wrong. Reported to the caller, which in a persistent
/// worker must not exit.
class UsageException implements Exception {
  const UsageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Arguments of one command, from the command line or, as the last one, a
/// `@paramsfile` with one argument per line.
class Args {
  Args._(this._values);

  static Args parse(String command, Iterable<String> argv) {
    final allowed = _optionsByCommand[command]!;
    final values = <String, List<String>>{};
    final list = argv.toList();
    for (var i = 0; i < list.length; i++) {
      final arg = list[i];
      final name = arg.startsWith('--') ? arg.substring(2) : null;
      if (name != null && (_flagsByCommand[command]?.contains(name) ?? false)) {
        values[name] = const ['true'];
        continue;
      }
      if (name == null || !allowed.contains(name) || i + 1 >= list.length) {
        throw UsageException('kernel_tool $command: unexpected argument $arg');
      }
      (values[name] ??= []).add(list[++i]);
    }
    return Args._(values);
  }

  /// [argv] with a `@paramsfile` replaced by the file's lines.
  static Iterable<String> expand(Iterable<String> argv) sync* {
    for (final arg in argv) {
      if (arg.startsWith('@')) {
        yield* const LineSplitter().convert(
          File(arg.substring(1)).readAsStringSync(),
        );
      } else {
        yield arg;
      }
    }
  }

  final Map<String, List<String>> _values;

  List<String> all(String name) => _values[name] ?? const [];

  bool flag(String name) => all(name).isNotEmpty;

  String? optional(String name) => all(name).isEmpty ? null : all(name).last;

  String one(String name) {
    final v = optional(name);
    if (v == null) {
      throw UsageException('kernel_tool: --$name is required');
    }
    return v;
  }

  /// The `--dep-modules`/`--dep-manifest` pairs, dependencies first.
  List<Manifest> depManifests() {
    final dirs = all('dep-modules');
    final files = all('dep-manifest');
    if (dirs.length != files.length) {
      throw const UsageException(
        'kernel_tool: --dep-modules and --dep-manifest must pair up',
      );
    }
    return [
      for (var i = 0; i < dirs.length; i++) Manifest.read(dirs[i], files[i]),
    ];
  }
}
