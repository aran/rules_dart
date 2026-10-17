// Copies files into a declared output directory: the staging step of
// `assemble_source_dir` in `dart/private/source_set.bzl`.
//
// It ports the destination rules of bazel-lib's `copy_to_directory` (3.7.2,
// `tools/copy_to_directory/main.go`) for the options rules_dart passes:
// `root_paths`, `replace_prefixes` and `include_external_repositories`. Each file
// is placed at the path those options give, in the order the Go tool applies them.
// Package filters and path patterns are left out, since their defaults match every
// file. Two files that map to one destination are an error, unless they share a
// short path and size, which is how a source file and its copy in `bazel-out` meet.
//
// The arguments are one params file, one value per line (the action writes it in
// multiline format):
//
//   <dst>                                  the output directory
//   --root <root>                          once per root path
//   --replace <key> <value>                once per replace prefix
//   --external <glob>                      once per include_external_repositories pattern
//   --workspace <name>                     the target's workspace; "" for the main repository
//   --file <path> <short_path> <workspace> <workspace_path>
//                                          once per input file, in order
//
// `path` is the file to copy. `workspace` is the repository the file comes from,
// `""` for the main one. `workspace_path` is its repository-relative path.
//
// Files are copied as they are: output bytes equal input bytes. Modes and mtimes
// are not carried over, as with copy_to_directory's default settings. Symlinks are
// followed. Copies run on ten concurrent workers, as the Go tool's do.
//
// This is a `dart_binary` built for the exec platform with only `dart:io`, so
// `dart_source_set` and the staging rules can name it as a toolchain tool.

import 'dart:async';
import 'dart:io';

/// The number of files copied at once, as the Go tool's copy workers.
const int copyWorkers = 10;

/// A failure to plan or perform the copy. The message is for the build log.
class CopyError implements Exception {
  CopyError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One input file, as the params file names it.
class SourceFile {
  const SourceFile({
    required this.path,
    required this.shortPath,
    required this.workspace,
    required this.workspacePath,
  });

  final String path;
  final String shortPath;
  final String workspace;
  final String workspacePath;
}

/// A parsed params file.
class Request {
  Request({
    required this.dst,
    required this.rootPaths,
    required this.replacePrefixes,
    required this.includeExternal,
    required this.targetWorkspace,
    required this.files,
  });

  final String dst;
  final List<String> rootPaths;
  final Map<String, String> replacePrefixes;
  final List<String> includeExternal;
  final String targetWorkspace;
  final List<SourceFile> files;
}

/// Parses the params file's lines. See the library's header for the layout.
Request parseRequest(List<String> lines) {
  var i = 0;
  String next() {
    if (i >= lines.length) {
      throw FormatException('params file ends inside a record');
    }
    return lines[i++];
  }

  final dst = next();
  final roots = <String>[];
  final replace = <String, String>{};
  final external = <String>[];
  var target = '';
  final files = <SourceFile>[];
  while (i < lines.length) {
    final tag = next();
    switch (tag) {
      case '--root':
        roots.add(next());
      case '--replace':
        final key = next();
        replace[key] = next();
      case '--external':
        external.add(next());
      case '--workspace':
        target = next();
      case '--file':
        files.add(
          SourceFile(
            path: next(),
            shortPath: next(),
            workspace: next(),
            workspacePath: next(),
          ),
        );
      default:
        throw FormatException('unknown record "$tag" in params file');
    }
  }
  return Request(
    dst: dst,
    rootPaths: roots,
    replacePrefixes: replace,
    includeExternal: external,
    targetWorkspace: target,
    files: files,
  );
}

/// Copies every file of [request] to its destination. Throws [CopyError] on a
/// destination collision, before anything is copied.
Future<void> copyTree(Request request) async {
  final copies = planCopies(request);
  var next = 0;
  Future<void> worker() async {
    while (next < copies.length) {
      final copy = copies[next++];
      final bytes = await File(copy.src).readAsBytes();
      await File(copy.dst).writeAsBytes(bytes);
    }
  }

  await Future.wait([for (var w = 0; w < copyWorkers; w++) worker()]);
}

/// One planned copy.
class PlannedCopy {
  const PlannedCopy(this.src, this.dst);

  final String src;
  final String dst;
}

/// Works out where each file goes and creates the directories, without copying.
///
/// Files are planned in order. A file already planned to the same destination
/// is dropped if it has the same short path and size, and is an error otherwise.
List<PlannedCopy> planCopies(Request request) {
  final globs = _Globs();
  final planned = <String, SourceFile>{};
  final copies = <PlannedCopy>[];
  final madeDirs = <String>{};
  for (final file in request.files) {
    final out = _outputPath(file, request, globs);
    if (out == null) continue;
    final dup = planned[out];
    if (dup != null) {
      if (dup.shortPath == file.shortPath &&
          File(dup.path).lengthSync() == File(file.path).lengthSync()) {
        continue;
      }
      throw CopyError(
        "duplicate output file '$out' configured from source files "
        "'${dup.path}' and '${file.path}'",
      );
    }
    planned[out] = file;
    final dir = _dir(out);
    if (madeDirs.add(dir)) {
      Directory(dir).createSync(recursive: true);
    }
    copies.add(PlannedCopy(file.path, out));
  }
  return copies;
}

/// The destination of [file], or `null` if it is not copied.
///
/// Port of `calculateOutputPath` in the Go tool. Each step matches the Go code.
String? _outputPath(SourceFile file, Request request, _Globs globs) {
  // include_external_repositories. A file from the target's own repository is
  // always included, and so is any file whose repository name is empty.
  if (file.workspace.isNotEmpty &&
      file.workspace != request.targetWorkspace &&
      !globs.anyMatch(request.includeExternal, file.workspace)) {
    return null;
  }

  var out = file.workspacePath;

  // root_paths: the longest root that matches the file's directory is stripped.
  final root = globs.longest(request.rootPaths, _dir(out));
  if (root.match.isNotEmpty) {
    out = _trimLeadingSlash(out.substring(root.match.length));
  }

  // replace_prefixes: the longest matching key is replaced, keys in sorted
  // order so that a tie is settled the same way on every run.
  final keys = request.replacePrefixes.keys.toList()..sort();
  final replace = globs.longest(keys, out);
  if (replace.match.isNotEmpty) {
    final value = request.replacePrefixes[keys[replace.index]]!;
    out = value + out.substring(replace.match.length);
  }

  return _join(request.dst, out);
}

// The path helpers below follow Go's `path` package, which the Go tool uses.

/// Go's `path.Clean`.
String _clean(String path) {
  if (path.isEmpty) return '.';
  final rooted = path.startsWith('/');
  final parts = <String>[];
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!rooted) {
        parts.add('..');
      }
    } else {
      parts.add(seg);
    }
  }
  final joined = parts.join('/');
  if (rooted) return '/$joined';
  return joined.isEmpty ? '.' : joined;
}

/// Go's `path.Dir`.
String _dir(String path) {
  final slash = path.lastIndexOf('/');
  return _clean(path.substring(0, slash + 1));
}

/// Go's `path.Join` for two elements.
String _join(String a, String b) {
  final parts = [a, b].where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  return _clean(parts.join('/'));
}

String _trimLeadingSlash(String s) => s.startsWith('/') ? s.substring(1) : s;

/// Matches glob patterns with the semantics of `doublestar.Match`, as the Go
/// tool uses it. Patterns are cached by their text.
class _Globs {
  final Map<String, _Glob> _cache = {};

  _Glob _of(String pattern) =>
      _cache.putIfAbsent(pattern, () => _Glob(pattern));

  /// Whether [text] matches any of [globs].
  bool anyMatch(List<String> globs, String text) =>
      globs.any((g) => _of(g).matches(text));

  /// Go's `longestGlobsMatch`: the longest prefix of [text] that some glob
  /// matches, and the index of the first glob that matches it. The result is
  /// empty when no glob matches.
  ({String match, int index}) longest(List<String> globs, String text) {
    var match = '';
    var index = 0;
    for (var i = 0; i < globs.length; i++) {
      final m = _of(globs[i]).longestPrefix(text);
      if (m.length > match.length) {
        match = m;
        index = i;
      }
    }
    return (match: match, index: index);
  }
}

/// One glob pattern. A pattern with no metacharacters is compared as text.
class _Glob {
  _Glob(this.pattern)
    : _literal = _isLiteral(pattern) ? pattern : null,
      _regex = _isLiteral(pattern) ? null : RegExp('^${_translate(pattern)}\$');

  final String pattern;
  final String? _literal;
  final RegExp? _regex;

  static bool _isLiteral(String pattern) =>
      !RegExp(r'[*?\[\]{}\\]').hasMatch(pattern);

  bool matches(String text) {
    final literal = _literal;
    return literal != null ? text == literal : _regex!.hasMatch(text);
  }

  /// The longest prefix of [text] this pattern matches, of at least one
  /// character, or empty. Go's `longestGlobMatch` tries each prefix from the
  /// longest down, and so does this, so a pattern can match part of a segment.
  String longestPrefix(String text) {
    final literal = _literal;
    if (literal != null) {
      return literal.isNotEmpty && text.startsWith(literal) ? literal : '';
    }
    for (var n = text.length; n >= 1; n--) {
      final candidate = text.substring(0, n);
      if (_regex!.hasMatch(candidate)) return candidate;
    }
    return '';
  }

  /// Characters that need a backslash inside a regular expression class.
  static const _classSpecial = r'\^[]';

  /// Translates a glob to a regular expression body. `*` and `?` do not cross
  /// `/`. `**` as a whole segment spans any number of segments, including none.
  /// Also supported: `[...]` classes (`!` or `^` negates), `{a,b}` alternatives,
  /// and `\` escapes.
  static String _translate(String pattern) {
    final segments = pattern.split('/');
    final out = StringBuffer();
    var skipSeparator = false;
    for (var k = 0; k < segments.length; k++) {
      final seg = segments[k];
      final last = k == segments.length - 1;
      if (seg == '**') {
        if (k == 0) {
          out.write(last ? '.*' : '(?:.*/)?');
        } else if (last) {
          out.write('(?:/.*)?');
        } else {
          out.write('/(?:.*/)?');
        }
        skipSeparator = !last;
        continue;
      }
      if (k > 0 && !skipSeparator) out.write('/');
      skipSeparator = false;
      out.write(_segment(seg));
    }
    return out.toString();
  }

  static String _segment(String seg) {
    final out = StringBuffer();
    var braces = 0;
    for (var i = 0; i < seg.length; i++) {
      final c = seg[i];
      switch (c) {
        case '*':
          out.write('[^/]*');
        case '?':
          out.write('[^/]');
        case '[':
          final close = seg.indexOf(']', i + 2);
          if (close < 0) {
            throw FormatException('bad glob "$seg": unclosed [');
          }
          var body = seg.substring(i + 1, close);
          var negate = false;
          if (body.startsWith('!') || body.startsWith('^')) {
            negate = true;
            body = body.substring(1);
          }
          out.write(negate ? '[^' : '[');
          for (final ch in body.split('')) {
            out.write(_classSpecial.contains(ch) ? '\\$ch' : ch);
          }
          out.write(']');
          i = close;
        case '{':
          braces++;
          out.write('(?:');
        case '}':
          if (braces == 0) {
            out.write(RegExp.escape(c));
          } else {
            braces--;
            out.write(')');
          }
        case ',':
          out.write(braces > 0 ? '|' : ',');
        case '\\':
          if (i + 1 >= seg.length) {
            throw FormatException('bad glob "$seg": trailing \\');
          }
          i++;
          out.write(RegExp.escape(seg[i]));
        default:
          out.write(RegExp.escape(c));
      }
    }
    if (braces != 0) {
      throw FormatException('bad glob "$seg": unclosed {');
    }
    return out.toString();
  }
}

Future<void> main(List<String> args) async {
  final lines = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@')) {
      lines.addAll(await File(arg.substring(1)).readAsLines());
    } else {
      lines.add(arg);
    }
  }
  try {
    await copyTree(parseRequest(lines));
  } on CopyError catch (e) {
    stderr.writeln('copy_tree: ${e.message}');
    exitCode = 1;
  }
}
