// The command line of `bazel run @rules_dart//dart/format`,
// `@rules_dart//dart/fix` and `@rules_dart//dart/unused_deps`.
//
// After the tool's own `--dry-run`, the arguments are those of `bazel build`:
// flags and target patterns, with `--` before patterns that start with `-`.
// They are passed to the tool's build as given, after the flags it sets
// itself, so `--config=deep //:x` formats exactly what `bazel build
// --config=deep //:x` would build, and Bazel rejects what it would reject. A
// flag the tool sets is refused, since the caller's would override it.

/// The binary's own options, which its BUILD target passes; `--aspect=` only
/// for a tool whose output group an aspect makes.
const _internal = ['--command=', '--aspect=', '--output-group='];
const _required = ['--command=', '--output-group='];

/// The `bazel build` flags the tool sets, by name.
const reservedFlags = [
  'aspects',
  'output_groups',
  'build_event_json_file',
  'run_validations',
];

/// A command line the tool cannot run.
class UsageException implements Exception {
  UsageException(this.message, [this.command]);
  final String message;

  /// `format`, `fix` or `unused_deps`, once known.
  final String? command;
}

/// The tool's command line, parsed.
class ApplyArgs {
  ApplyArgs({
    required this.command,
    required this.aspect,
    required this.group,
    required this.dryRun,
    required this.bazelArgs,
  });

  /// `format`, `fix` or `unused_deps`.
  final String command;

  /// The aspect making [group], by canonical label, or `null` when the
  /// targets make it themselves.
  final String? aspect;

  /// The output group holding the files the tool reads.
  final String group;
  final bool dryRun;

  /// The caller's `bazel build` arguments, in order.
  final List<String> bazelArgs;

  /// The `bazel build` command line, writing its events to [events].
  List<String> buildArgs(String events) => [
    'build',
    if (aspect case final aspect?) '--aspects=$aspect',
    // Without a `+`, that group alone, not the targets' default outputs.
    '--output_groups=$group',
    // Nor their validations: an import check has no say in a file's format,
    // and the unused-dependency check would fail what the tool fixes.
    '--norun_validations',
    '--build_event_json_file=$events',
    ...bazelArgs,
  ];
}

/// Parses [args]: the binary's own options first, then the caller's.
///
/// Throws [UsageException] when an option is missing, the caller names
/// nothing, or the caller passes a flag in [reservedFlags].
ApplyArgs parseArgs(List<String> args) {
  final internal = <String, String>{};
  var i = 0;
  for (; i < args.length; i++) {
    final prefix = _internal.where(args[i].startsWith).firstOrNull;
    if (prefix == null || internal.containsKey(prefix)) break;
    internal[prefix] = args[i].substring(prefix.length);
  }
  if (!_required.every(internal.containsKey)) {
    throw UsageException('${_required.join(', ')} are required');
  }
  final command = internal['--command=']!;

  var dryRun = false;
  final bazelArgs = <String>[];
  var patternsOnly = false;
  for (final arg in args.skip(i)) {
    if (patternsOnly) {
      bazelArgs.add(arg);
      continue;
    }
    if (arg == '--') {
      patternsOnly = true;
    } else if (arg == '--dry-run') {
      dryRun = true;
      continue;
    } else if (_reserved(arg) case final name?) {
      throw UsageException(
        '--$name is set by this tool, so it cannot be passed',
        command,
      );
    }
    bazelArgs.add(arg);
  }
  if (bazelArgs.isEmpty) {
    throw UsageException('name the targets to $command', command);
  }
  return ApplyArgs(
    command: command,
    aspect: internal['--aspect='],
    group: internal['--output-group=']!,
    dryRun: dryRun,
    bazelArgs: bazelArgs,
  );
}

/// The reserved flag [arg] sets, in any of Bazel's spellings.
String? _reserved(String arg) {
  if (!arg.startsWith('--')) return null;
  final name = arg.substring(2).split('=').first;
  for (final flag in reservedFlags) {
    if (name == flag || name == 'no$flag') return flag;
  }
  return null;
}
