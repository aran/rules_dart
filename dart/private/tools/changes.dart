// The rewrites a build action proposes for a target's own sources, and how
// `bazel run @rules_dart//dart/format` and `@rules_dart//dart/fix` write them
// into the workspace.
//
// The `dart_analyze` aspect's format and fix actions each write one changes
// file: JSON naming the target, and for every source the action would change,
// its workspace path, the SHA-256 of the bytes the action read, and the whole
// new content. The format check fails on a non-empty one, so the check and the
// rewrite are one computation. The applier writes the content only where the
// workspace still holds the bytes the action read.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// One file's proposed new content.
class Change {
  Change({required this.path, required this.sha256, required this.content});

  /// Workspace-relative, `/`-separated.
  final String path;

  /// Hex SHA-256 of the bytes the action read for [path].
  final String sha256;
  final String content;

  Map<String, String> toJson() => {
    'path': path,
    'sha256': sha256,
    'content': content,
  };
}

/// What one action proposes for one target.
class ChangeSet {
  ChangeSet({
    required this.target,
    required this.changes,
    this.dropped = const [],
  });

  /// Reads a changes file, failing with [FormatException] on anything this
  /// library did not write.
  factory ChangeSet.read(String path) {
    final Object? json;
    try {
      json = jsonDecode(File(path).readAsStringSync());
    } on FormatException catch (e) {
      throw FormatException('$path is not valid JSON: ${e.message}');
    }
    if (json is! Map ||
        json['target'] is! String ||
        json['changes'] is! List ||
        json['dropped'] is! List) {
      throw FormatException('$path is not a changes file');
    }
    return ChangeSet(
      target: json['target'] as String,
      changes: [
        for (final c in json['changes'] as List)
          if (c case {
            'path': final String p,
            'sha256': final String s,
            'content': final String content,
          })
            Change(path: p, sha256: s, content: content)
          else
            throw FormatException('$path: malformed change $c'),
      ],
      dropped: [
        for (final d in json['dropped'] as List)
          if (d is String)
            d
          else
            throw FormatException('$path: malformed dropped entry $d'),
      ],
    );
  }

  /// The label of the target whose files these are.
  final String target;
  final List<Change> changes;

  /// Paths of files the action changed but may not write: generated files,
  /// which only a fix can reach.
  final List<String> dropped;

  /// Writes this set to [path], sorted so the bytes are reproducible.
  void write(String path) {
    final sorted = [...changes]..sort((a, b) => a.path.compareTo(b.path));
    final json = {
      'target': target,
      'changes': [for (final c in sorted) c.toJson()],
      'dropped': [...dropped]..sort(),
    };
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
    );
  }
}

/// Hex SHA-256 of [bytes].
String digest(List<int> bytes) => sha256.convert(bytes).toString();

/// Writes [sets] into [workspace], or with [dryRun] prints them as diffs to
/// [out]. Returns the exit code.
///
/// Nothing is written unless everything can be: two targets proposing
/// different content for one file, or a file whose bytes differ from the ones
/// the action read, refuses the whole run. [verb] names what the changes do
/// (`formatted`, `fixed`).
int applyChanges(
  List<ChangeSet> sets, {
  required String workspace,
  required bool dryRun,
  required String verb,
  required StringSink out,
  required StringSink err,
}) {
  final byPath = <String, Change>{};
  final owners = <String, List<String>>{};
  final conflicts = <String>{};
  for (final set in sets) {
    for (final change in set.changes) {
      if (!_isWorkspacePath(change.path)) {
        err.writeln(
          'error: ${set.target} proposes a change to `${change.path}`, '
          'which is not a path inside the workspace.',
        );
        return 1;
      }
      (owners[change.path] ??= []).add(set.target);
      final seen = byPath[change.path];
      if (seen == null) {
        byPath[change.path] = change;
      } else if (seen.content != change.content ||
          seen.sha256 != change.sha256) {
        conflicts.add(change.path);
      }
    }
  }
  if (conflicts.isNotEmpty) {
    for (final path in conflicts.toList()..sort()) {
      err.writeln(
        'error: $path is $verb differently by ${owners[path]!.join(' and ')}.',
      );
    }
    err.writeln('Nothing was written. Run them one at a time.');
    return 1;
  }

  final paths = byPath.keys.toList()..sort();
  final stale = [
    for (final path in paths)
      if (!_holds(_join(workspace, path), byPath[path]!.sha256)) path,
  ];
  if (stale.isNotEmpty) {
    for (final path in stale) {
      err.writeln('error: $path changed after the build read it.');
    }
    err.writeln('Nothing was written. Run again to recompute the changes.');
    return 1;
  }

  for (final path in paths) {
    final change = byPath[path]!;
    final file = File(_join(workspace, path));
    if (dryRun) {
      printDiff(path, file.readAsStringSync(), change.content, out);
    } else {
      // By content rather than by copying a file: build outputs are
      // read-only, and a copy can carry that mode onto the user's source.
      file.writeAsStringSync(change.content);
      out.writeln('$verb $path');
    }
  }

  final dropped = {for (final set in sets) ...set.dropped}.toList()..sort();
  for (final path in dropped) {
    err.writeln(
      'warning: $path is generated, so its changes were not written. Fix '
      'the generator or its inputs.',
    );
  }

  final files = paths.length == 1 ? 'file' : 'files';
  out.writeln(
    dryRun
        ? '${paths.length} $files would be $verb (dry run, nothing written).'
        : '${paths.length} $files $verb.',
  );
  return 0;
}

/// Whether [path] holds bytes whose digest is [expected]. A missing file holds
/// none.
bool _holds(String path, String expected) {
  final file = File(path);
  return file.existsSync() && digest(file.readAsBytesSync()) == expected;
}

bool _isWorkspacePath(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains(r'\') &&
    !path.contains(':') &&
    !path.split('/').any((s) => s.isEmpty || s == '.' || s == '..');

String _join(String base, String relative) =>
    [base, ...relative.split('/')].join(Platform.pathSeparator);

/// Lines of unchanged context printed either side of a change.
const _contextLines = 3;

/// Prints a unified-style diff of [before] to [after] for [path].
///
/// One hunk from the first differing line to the last: it over-reports a file
/// with distant edits, but is plainly correct, which matters more in what the
/// user reads before letting a tool rewrite their sources.
void printDiff(String path, String before, String after, StringSink out) {
  final a = const LineSplitter().convert(before);
  final b = const LineSplitter().convert(after);
  out.writeln('--- a/$path');
  out.writeln('+++ b/$path');

  final shorter = a.length < b.length ? a.length : b.length;
  var prefix = 0;
  while (prefix < shorter && a[prefix] == b[prefix]) {
    prefix++;
  }
  // Capped at what the prefix left, or the two scans could claim the same
  // lines ("a\na" against "a") and invert the ranges.
  var suffix = 0;
  while (suffix < shorter - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  final aEnd = a.length - suffix;
  final bEnd = b.length - suffix;
  if (prefix == aEnd && prefix == bEnd) {
    // Only line endings or a final newline differ.
    out.writeln('(whitespace at line ends differs)');
    return;
  }
  final leading = prefix < _contextLines ? prefix : _contextLines;
  final trailing = suffix < _contextLines ? suffix : _contextLines;
  final start = prefix - leading;
  out.writeln(
    '@@ -${_range(start, aEnd + trailing - start)} '
    '+${_range(start, bEnd + trailing - start)} @@',
  );
  for (var i = start; i < prefix; i++) {
    out.writeln(' ${a[i]}');
  }
  for (var i = prefix; i < aEnd; i++) {
    out.writeln('-${a[i]}');
  }
  for (var i = prefix; i < bEnd; i++) {
    out.writeln('+${b[i]}');
  }
  for (var i = aEnd; i < aEnd + trailing; i++) {
    out.writeln(' ${a[i]}');
  }
}

/// A unified-diff range; an empty one starts at the line before.
String _range(int start, int count) =>
    count == 0 ? '$start,0' : '${start + 1},$count';
