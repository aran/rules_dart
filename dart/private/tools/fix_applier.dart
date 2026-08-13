// The `bazel run` half of `dart_fix`: copies fixes that a hermetic build action
// already computed into the user's real source tree.
//
// Pure Dart with no package dependencies, so it builds as a plain `dart_binary`
// and runs on every host platform the rule set supports.
import 'dart:convert';
import 'dart:io';

const _usage =
    'usage: fix_applier --manifest <manifest-file> --fixes <fixes-dir> '
    '[--dry-run]';

/// Lines of unchanged context printed either side of a change in `--dry-run`.
const _contextLines = 3;

void main(List<String> args) {
  String? manifestPath;
  String? fixesDir;
  var dryRun = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--manifest':
        manifestPath = _flagValue(args, ++i);
      case '--fixes':
        fixesDir = _flagValue(args, ++i);
      case '--dry-run':
        dryRun = true;
      default:
        _usageError('unknown argument ${args[i]}');
    }
  }
  // `bazel run //pkg:fix -- --dry-run` forwards only the user's own arguments
  // to the executable, so the rule has nowhere on the command line to inject
  // the manifest and fixes directory; a shell wrapper could, but this rule set
  // stays shell-free for Windows. The rule supplies them through
  // RunEnvironmentInfo instead. An explicit flag still wins, which keeps the
  // tool runnable by hand and debuggable outside Bazel.
  final env = Platform.environment;
  manifestPath ??= _nonEmpty(env['DART_FIX_MANIFEST']);
  fixesDir ??= _nonEmpty(env['DART_FIX_FIXES']);
  if (manifestPath == null || fixesDir == null) {
    _usageError(
      '--manifest and --fixes are required (or DART_FIX_MANIFEST and '
      'DART_FIX_FIXES in the environment)',
    );
  }

  // Bazel sets BUILD_WORKSPACE_DIRECTORY only under `bazel run`. The manifest
  // names files by workspace-relative path, so without it there is no anchor to
  // resolve them against; falling back to the cwd would silently write source
  // files into whatever directory the binary happened to be launched from. A
  // hard error is the only outcome that cannot corrupt an unrelated tree.
  // `--dry-run` needs it just as much: the diff is against the workspace copy.
  final workspace = _nonEmpty(env['BUILD_WORKSPACE_DIRECTORY']);
  if (workspace == null) {
    stderr.writeln(
      'fix_applier: BUILD_WORKSPACE_DIRECTORY is not set. Apply fixes with '
      '`bazel run` on the target; this tool cannot locate your source tree '
      'when invoked directly.',
    );
    exit(1);
  }

  if (!Directory(fixesDir).existsSync()) {
    stderr.writeln('fix_applier: fixes directory not found: $fixesDir');
    exit(1);
  }

  final manifest = _readManifest(manifestPath);
  final fixed = _entries(manifest, 'fixed', manifestPath);
  final dropped = _entries(manifest, 'dropped', manifestPath);

  // Resolve every source up front. A missing staged file means the action that
  // produced the manifest is broken; discovering that halfway through leaves
  // the tree half-fixed, which is far harder to reason about than not starting.
  final pending = <_Fix>[];
  for (final entry in fixed) {
    final relative = _requireString(entry, 'workspace', 'fixed', manifestPath);
    final staged = File(_join(fixesDir, relative));
    if (!staged.existsSync()) {
      stderr.writeln(
        'fix_applier: manifest lists $relative but ${staged.path} does not '
        'exist',
      );
      exit(1);
    }
    pending.add(_Fix(relative, staged, File(_join(workspace, relative))));
  }

  try {
    for (final fix in pending) {
      if (dryRun) {
        _printDiff(fix);
      } else {
        fix.destination.parent.createSync(recursive: true);
        // A whole-file overwrite is safe because `bazel run` rebuilds the fix
        // action before running this tool: the staged file was computed from
        // exactly the sources now on disk, so there are no concurrent edits to
        // preserve and nothing to merge.
        //
        // The bytes are copied by hand rather than with File.copySync because
        // build outputs are read-only; copySync can carry that mode onto the
        // destination and leave the user's own source file unwritable.
        fix.destination.writeAsBytesSync(fix.staged.readAsBytesSync());
        stdout.writeln('wrote ${fix.relative}');
      }
    }
  } on FileSystemException catch (e) {
    stderr.writeln('fix_applier: ${e.message}: ${e.path}');
    exit(1);
  }

  for (final entry in dropped) {
    final name =
        _optionalString(entry, 'workspace') ??
        _optionalString(entry, 'staged') ??
        '<unnamed file>';
    final reason =
        _optionalString(entry, 'reason') ?? 'not write-back eligible';
    stderr.writeln('fix_applier: warning: dropped $name ($reason)');
    stderr.writeln(
      '  A fix targeted a generated file. Fix the generator\'s inputs or the '
      'builder itself, not its output.',
    );
  }

  final files = pending.length == 1 ? 'file' : 'files';
  if (dryRun) {
    stdout.writeln(
      'fix_applier: ${pending.length} $files would be written, '
      '${dropped.length} dropped (dry run, nothing modified)',
    );
  } else {
    stdout.writeln(
      'fix_applier: ${pending.length} $files written, ${dropped.length} '
      'dropped',
    );
    if (pending.isNotEmpty) {
      // One pass can unblock fixes the analyzer could not see before, and some
      // fixes are not idempotent, so a clean run is the only completion signal.
      stdout.writeln(
        'fix_applier: fixes are not always idempotent; re-run until no files '
        'are written.',
      );
    }
  }
}

/// A single write-back: where the fixed bytes are, and where they belong.
class _Fix {
  _Fix(this.relative, this.staged, this.destination);

  /// Workspace-relative path, as it appears in the manifest and in output.
  final String relative;
  final File staged;
  final File destination;
}

String _flagValue(List<String> args, int index) {
  if (index >= args.length) {
    _usageError('${args[index - 1]} requires a value');
  }
  return args[index];
}

Never _usageError(String message) {
  stderr.writeln('fix_applier: $message');
  stderr.writeln(_usage);
  exit(64);
}

Map<String, dynamic> _readManifest(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('fix_applier: manifest not found: $path');
    exit(1);
  }
  Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('fix_applier: $path is not valid JSON: ${e.message}');
    exit(1);
  } on FileSystemException catch (e) {
    stderr.writeln('fix_applier: cannot read $path: ${e.message}');
    exit(1);
  }
  if (decoded is! Map<String, dynamic>) {
    stderr.writeln('fix_applier: $path must contain a JSON object');
    exit(1);
  }
  return decoded;
}

List<Map<String, dynamic>> _entries(
  Map<String, dynamic> manifest,
  String key,
  String manifestPath,
) {
  final value = manifest[key];
  if (value == null) return const [];
  if (value is! List) {
    stderr.writeln('fix_applier: $manifestPath: "$key" must be a list');
    exit(1);
  }
  return [
    for (final entry in value)
      if (entry is Map<String, dynamic>)
        entry
      else
        _entryTypeError(manifestPath, key),
  ];
}

Never _entryTypeError(String manifestPath, String key) {
  stderr.writeln(
    'fix_applier: $manifestPath: every "$key" entry must be a JSON object',
  );
  exit(1);
}

String _requireString(
  Map<String, dynamic> entry,
  String key,
  String listName,
  String manifestPath,
) {
  final value = _optionalString(entry, key);
  if (value == null) {
    stderr.writeln(
      'fix_applier: $manifestPath: a "$listName" entry is missing a string '
      '"$key"',
    );
    exit(1);
  }
  return value;
}

String? _optionalString(Map<String, dynamic> entry, String key) {
  final value = entry[key];
  return value is String && value.isNotEmpty ? value : null;
}

String? _nonEmpty(String? value) =>
    value != null && value.isNotEmpty ? value : null;

/// Joins a workspace-relative manifest path onto [base].
///
/// Manifest paths are always POSIX-style; rewriting the separators keeps the
/// result a well-formed native path on Windows.
String _join(String base, String relative) =>
    [base, ...relative.split('/')].join(Platform.pathSeparator);

/// Prints a unified-style diff of [fix] without touching the workspace.
///
/// This trims the common prefix and suffix and dumps everything between them as
/// one hunk. That over-reports when a file has several distant edits, but it is
/// obviously correct, which matters more here than minimal output: the diff is
/// what the user reads before letting the tool rewrite their sources.
void _printDiff(_Fix fix) {
  // A fix can create a file that does not exist yet; an empty "before" renders
  // that as a pure addition rather than an error.
  final before = fix.destination.existsSync()
      ? _lines(fix.destination)
      : const <String>[];
  final after = _lines(fix.staged);

  stdout.writeln('--- a/${fix.relative}');
  stdout.writeln('+++ b/${fix.relative}');

  final shorter = before.length < after.length ? before.length : after.length;
  var prefix = 0;
  while (prefix < shorter && before[prefix] == after[prefix]) {
    prefix++;
  }
  // Cap the suffix scan at what the prefix left behind, or the two scans can
  // claim the same lines (e.g. "a\na" against "a") and produce inverted ranges.
  var suffix = 0;
  while (suffix < shorter - prefix &&
      before[before.length - 1 - suffix] == after[after.length - 1 - suffix]) {
    suffix++;
  }

  final beforeEnd = before.length - suffix;
  final afterEnd = after.length - suffix;
  if (prefix == beforeEnd && prefix == afterEnd) {
    stdout.writeln('(no textual difference)');
    return;
  }

  final leading = prefix < _contextLines ? prefix : _contextLines;
  final trailing = suffix < _contextLines ? suffix : _contextLines;
  final start = prefix - leading;
  stdout.writeln(
    '@@ -${_range(start, beforeEnd + trailing - start)} '
    '+${_range(start, afterEnd + trailing - start)} @@',
  );
  for (var i = start; i < prefix; i++) {
    stdout.writeln(' ${before[i]}');
  }
  for (var i = prefix; i < beforeEnd; i++) {
    stdout.writeln('-${before[i]}');
  }
  for (var i = prefix; i < afterEnd; i++) {
    stdout.writeln('+${after[i]}');
  }
  for (var i = beforeEnd; i < beforeEnd + trailing; i++) {
    stdout.writeln(' ${before[i]}');
  }
}

List<String> _lines(File file) =>
    const LineSplitter().convert(file.readAsStringSync());

/// Formats a unified-diff range. An empty range starts at the preceding line,
/// which is what `diff` emits for a pure insertion into an empty file.
String _range(int start, int count) =>
    count == 0 ? '$start,0' : '${start + 1},$count';
