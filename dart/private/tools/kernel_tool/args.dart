import 'dart:convert';
import 'dart:io';

import 'manifest.dart';

const _optionsByCommand = {
  'module': {
    'runtime', 'snapshot', 'label', 'platform', 'target', 'libraries-spec',
    'libraries-target', 'package-config', 'multi-root', 'src', 'dep-modules',
    'dep-manifest', 'define', 'output-dir', 'manifest-output', 'package-name',
    'package-root', 'outline-tool', 'outline-dir', //
  },
  'entry': {
    'runtime', 'snapshot', 'sdk-root', 'label', 'platform', 'target',
    'package-config', 'multi-root', 'dep-modules', 'dep-manifest', 'define',
    'native-assets', 'main', 'output', 'selection-output',
    'unused-inputs-output', //
  },
  // What follows `--` is the compiler's own command line, passed on as it is.
  'frontend': {'runtime'},
  'link': {
    'label', 'entry', 'selection', 'dep-manifest', 'output', 'list-short-path',
    'entry-short-path', 'dep-short-path', 'workspace-name', //
  },
  'check': {
    'label',
    'package-config',
    'package-name',
    'package-root',
    'multi-root',
    'src',
    'dep-file', 'available-package', 'direct-package', 'dep', 'use-src',
    'dependent', 'report',
    'output', //
  },
  'digest': {'input', 'output'},
};

/// Options that stand alone, without a value.
const _flagsByCommand = {
  'module': {'track-creation-locations'},
  'entry': {'track-creation-locations'},
  'check': {'check-layering', 'check-cycle', 'generator-input', 'check-unused'},
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
  Args._(this._values, this.rest);

  static Args parse(String command, Iterable<String> argv) {
    final allowed = _optionsByCommand[command]!;
    final values = <String, List<String>>{};
    final list = argv.toList();
    var rest = const <String>[];
    for (var i = 0; i < list.length; i++) {
      final arg = list[i];
      if (arg == '--') {
        rest = list.sublist(i + 1);
        break;
      }
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
    return Args._(values, rest);
  }

  /// [argv] with a `@paramsfile` replaced by the file's lines. What follows
  /// a `--` is left as it is, since it is not this tool's to read.
  static Iterable<String> expand(Iterable<String> argv) sync* {
    var verbatim = false;
    for (final arg in argv) {
      if (verbatim || !arg.startsWith('@')) {
        verbatim = verbatim || arg == '--';
        yield arg;
        continue;
      }
      for (final line in const LineSplitter().convert(
        File(arg.substring(1)).readAsStringSync(),
      )) {
        verbatim = verbatim || line == '--';
        yield line;
      }
    }
  }

  final Map<String, List<String>> _values;

  /// What followed `--`, verbatim; empty when nothing did.
  final List<String> rest;

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

/// The target's own packages, by name, from its paired `--package-name` and
/// `--package-root` options.
Map<String, String> ownPackages(Args args) {
  final names = args.all('package-name');
  final roots = args.all('package-root');
  if (names.length != roots.length) {
    throw UsageException(
      'kernel_tool: ${names.length} --package-name for ${roots.length} '
      '--package-root',
    );
  }
  return {for (var i = 0; i < names.length; i++) names[i]: roots[i]};
}
