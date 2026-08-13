// Build-action runner for `dart fix` over a staged project directory.
//
// `dart fix --apply` rewrites sources in place, which an action cannot do: its
// inputs are a read-only sandbox and its outputs must be declared up front. So
// the staged project is copied to a scratch directory and fixed there, and only
// the files the rule declared write-back eligible are emitted. Pure Dart (no
// shell) so the action is portable to Windows.
import 'dart:convert';
import 'dart:io';

/// Recorded for every changed file outside the eligible set. One constant
/// string: the manifest says *that* a fix was discarded, and the rule's
/// excludes are what say why.
const _droppedReason = 'not write-back eligible';

/// Rewritten by this runner (see [_absolutizePackageConfig]), so its difference
/// from the staged original is self-inflicted rather than a discarded fix.
const _packageConfigPath = '.dart_tool/package_config.json';

void main(List<String> args) {
  String? dart;
  String? project;
  String? scratch;
  String? fixes;
  String? manifest;
  String? eligible;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dart':
        dart = args[++i];
      case '--project':
        project = args[++i];
      case '--scratch':
        scratch = args[++i];
      case '--fixes':
        fixes = args[++i];
      case '--manifest':
        manifest = args[++i];
      case '--eligible':
        eligible = args[++i];
      default:
        stderr.writeln('fix_runner: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (dart == null ||
      project == null ||
      scratch == null ||
      fixes == null ||
      manifest == null ||
      eligible == null) {
    stderr.writeln(
      'fix_runner: --dart, --project, --scratch, --fixes, '
      '--manifest, and --eligible are all required',
    );
    exit(64);
  }

  final writeBack = _readEligible(eligible);

  _copyTree(project, scratch);
  _absolutizePackageConfig(project, scratch);

  final result = Process.runSync(dart, ['fix', '--apply', scratch]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    exit(result.exitCode);
  }

  // Declared outputs must exist even when nothing was fixed.
  Directory(fixes).createSync(recursive: true);

  final fixed = <Map<String, String>>[];
  writeBack.forEach((staged, workspace) {
    if (!_differs('$project/$staged', '$scratch/$staged')) return;
    _copyFile('$scratch/$staged', '$fixes/$workspace');
    fixed.add({'staged': staged, 'workspace': workspace});
  });

  final dropped = _scanDropped(project, scratch, writeBack.keys.toSet());

  // Bazel actions must be reproducible; directory listings are not ordered.
  fixed.sort((a, b) => a['staged']!.compareTo(b['staged']!));
  dropped.sort((a, b) => a['staged']!.compareTo(b['staged']!));

  const encoder = JsonEncoder.withIndent('  ');
  File(manifest).writeAsStringSync(
    '${encoder.convert({'fixed': fixed, 'dropped': dropped})}\n',
  );
}

/// Reads the rule's `<staged-relative>\t<workspace-relative>` write-back list.
Map<String, String> _readEligible(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('fix_runner: --eligible file not found: $path');
    exit(64);
  }
  final entries = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final fields = line.split('\t');
    if (fields.length != 2 || fields[0].isEmpty || fields[1].isEmpty) {
      stderr.writeln('fix_runner: malformed --eligible entry: $line');
      exit(64);
    }
    entries[fields[0]] = fields[1];
  }
  return entries;
}

/// Copies the tree at [from] to [to], resolving symlinks to their contents.
void _copyTree(String from, String to) {
  Directory(to).createSync(recursive: true);
  for (final entity in Directory(from).listSync(followLinks: false)) {
    final name = _relative(from, entity.path);
    if (FileSystemEntity.isDirectorySync(entity.path)) {
      _copyTree(entity.path, '$to/$name');
    } else if (FileSystemEntity.isFileSync(entity.path)) {
      _copyFile(entity.path, '$to/$name');
    }
  }
}

/// Copies [from] to [to] by content, creating parent directories.
///
/// Not `File.copySync`, which carries the source's mode across: Bazel stages
/// action inputs read-only, and the fixer has to be able to rewrite the copy.
/// Reading also flattens a staged symlink into a real file, so no write can
/// follow one back out into the sandbox.
void _copyFile(String from, String to) {
  final dest = File(to);
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(File(from).readAsBytesSync());
}

/// Repoints the scratch copy's package config at the packages that live
/// outside the copied tree.
///
/// Only the project directory is copied; the pub packages its config reaches
/// through `../../<name>.extpkgs/...` stay where the sandbox staged them, and
/// a relative URI no longer finds them from wherever scratch is. Absolute URIs
/// are how the copy keeps resolving those without copying pub trees or
/// symlinking them in, which Windows cannot do unprivileged anyway.
void _absolutizePackageConfig(String project, String scratch) {
  final file = File('$scratch/$_packageConfigPath');
  if (!file.existsSync()) return;
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln('fix_runner: ignoring unparseable ${file.path}: $e');
    return;
  }
  if (decoded is! Map || decoded['packages'] is! List) return;

  // Trailing slashes: the URIs resolve against the config's directory, not
  // against the config file, and `demo.proj/` must not prefix-match a sibling
  // `demo.projX`.
  final anchor = Uri.directory(Directory('$project/.dart_tool').absolute.path);
  final projectRoot = Uri.directory(
    Directory(project).absolute.path,
  ).toString();
  var rewrote = false;
  for (final package in decoded['packages'] as List) {
    if (package is! Map) continue;
    final root = package['rootUri'];
    if (root is! String) continue;
    final parsed = Uri.tryParse(root);
    if (parsed == null || parsed.hasScheme) continue;
    final resolved = anchor.resolveUri(parsed).toString();
    // A URI that stays inside the project is left alone: the copy preserves
    // the tree below the project dir, so it resolves to the scratch file at
    // the same path. Pointing it at the original instead would split every
    // package into two identities — the scratch file the fixer analyzes and
    // the `package:` URI it imports itself by — and the analyzer reports type
    // errors between them, which costs the fixes that depend on resolution.
    if (resolved.startsWith(projectRoot)) continue;
    package['rootUri'] = resolved;
    rewrote = true;
  }
  if (rewrote) {
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(decoded)}\n',
    );
  }
}

/// Lists every changed file that no one asked to have written back.
///
/// Belt and braces: the rule excludes generated and read-only sources from the
/// fixed project, so this should always come back empty. A non-empty list means
/// the fixer reached something upstream meant to keep out of its way, and the
/// manifest is where that shows up rather than being silently discarded.
List<Map<String, String>> _scanDropped(
  String project,
  String scratch,
  Set<String> eligible,
) {
  final dropped = <Map<String, String>>[];
  final tree = Directory(scratch).listSync(recursive: true, followLinks: false);
  for (final entity in tree) {
    if (entity is! File) continue;
    final staged = _relative(scratch, entity.path);
    if (staged == _packageConfigPath || eligible.contains(staged)) continue;
    if (_differs('$project/$staged', entity.path)) {
      dropped.add({'staged': staged, 'reason': _droppedReason});
    }
  }
  return dropped;
}

/// The part of [path] below [root], in the `/`-separated form the eligible
/// list and the manifest use.
String _relative(String root, String path) {
  var rel = path.substring(root.length).replaceAll(r'\', '/');
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}

/// Whether the two paths hold different bytes. Two missing files match.
bool _differs(String original, String candidate) {
  final a = File(original);
  final b = File(candidate);
  final aExists = a.existsSync();
  if (aExists != b.existsSync()) return true;
  if (!aExists) return false;
  final aBytes = a.readAsBytesSync();
  final bBytes = b.readAsBytesSync();
  if (aBytes.length != bBytes.length) return true;
  for (var i = 0; i < aBytes.length; i++) {
    if (aBytes[i] != bBytes[i]) return true;
  }
  return false;
}
