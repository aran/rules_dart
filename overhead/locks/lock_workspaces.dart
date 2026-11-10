/// Which Bazel workspaces of a repository have a lock file to keep current,
/// and how to run Bazel in them without the developer's own settings.
library;

/// The file that marks a workspace as one that fails on purpose. Each line
/// that is neither blank nor a `#` comment is text the failure must print.
const expectedFailureFile = 'lock_expected_failure.txt';

/// The workspaces among [trackedFiles] (the repository's tracked paths, `/`
/// separated, relative to its root), as directories relative to the root,
/// `.` first and the rest sorted.
///
/// Only tracked files count, so nothing Bazel or the checkout ignores
/// (`bazel-*` symlinks, `.bazel_env`) is ever a workspace.
///
/// A workspace is a directory with a `MODULE.bazel`, with two exceptions:
///   * one inside another workspace other than the root, with no tracked
///     `MODULE.bazel.lock` of its own, is a module that workspace depends on
///     (a `local_path_override` fixture), resolved as part of it; with a
///     lock it is a workspace of its own, however deeply nested;
///   * one that [rootOverrides] names, the directories the root module
///     points `local_path_override` at, is resolved as part of the root,
///     unless it has a `.bazelversion` of its own because it is also
///     built on its own.
List<String> findWorkspaces(
  Iterable<String> trackedFiles, {
  Set<String> rootOverrides = const {},
}) {
  final tracked = trackedFiles.toSet();
  final modules = [
    for (final path in tracked)
      if (path == 'MODULE.bazel')
        '.'
      else if (path.endsWith('/MODULE.bazel'))
        path.substring(0, path.length - '/MODULE.bazel'.length),
  ]..sort();
  final workspaces = <String>[];
  for (final dir in modules) {
    if (dir == '.') continue;
    if (workspaces.any((w) => dir.startsWith('$w/')) &&
        !tracked.contains('$dir/MODULE.bazel.lock')) {
      continue;
    }
    if (rootOverrides.contains(dir) &&
        !tracked.contains('$dir/.bazelversion')) {
      continue;
    }
    workspaces.add(dir);
  }
  return [if (modules.contains('.')) '.', ...workspaces];
}

/// The directories, relative to the root, that [moduleBazel] (the root's
/// `MODULE.bazel`) points `local_path_override` at.
Set<String> localPathOverrides(String moduleBazel) => {
  for (final call in RegExp(
    r'local_path_override\(([^)]*)\)',
  ).allMatches(moduleBazel))
    if (RegExp(r'\bpath\s*=\s*"([^"]*)"').firstMatch(call[1]!) case final m?)
      _normalize(m[1]!),
};

String _normalize(String path) {
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..' && parts.isNotEmpty && parts.last != '..') {
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.isEmpty ? '.' : parts.join('/');
}

/// The texts a workspace's [expectedFailureFile] says its failure prints.
List<String> expectedFailureTexts(String contents) => [
  for (final raw in contents.split('\n'))
    if (raw.trim() case final line
        when line.isNotEmpty && !line.startsWith('#'))
      line,
];

/// Whether a Bazel step that exited [exitCode] with [output] failed the way
/// the workspace's [expectedFailureFile] says it fails: printing each of
/// [expected].
bool failedAsExpected(int exitCode, String output, List<String>? expected) =>
    exitCode != 0 &&
    expected != null &&
    expected.isNotEmpty &&
    expected.every(output.contains);

/// Whether a Bazel step passes: it succeeded, or it failed as expected, or
/// an earlier step of the workspace did ([afterExpectedFailure]). A Bazel
/// server reports a failed extension once, so a later step fails for the
/// same reason without saying it again.
bool stepPasses(
  int exitCode,
  String output,
  List<String>? expected, {
  bool afterExpectedFailure = false,
}) =>
    exitCode == 0 ||
    failedAsExpected(exitCode, output, expected) ||
    (afterExpectedFailure && expected != null);

/// What to tell the developer when [output], a failed Bazel step's, shows a
/// pinned commit (a `git_override`'s or a `git_repository`'s) that its remote
/// does not have, typically one not pushed yet; null for any other failure.
String? unfetchablePin(String output) {
  final match = _unfetchablePin.firstMatch(output);
  if (match == null) return null;
  return 'the pin of @${match[1]} names commit ${match[2]}, which its remote '
      'does not have. If it is not pushed yet, this workspace\'s lock can be '
      'checked or refreshed only after it is.';
}

/// Bazel's git_repository, failing to check out a commit it could not fetch.
final _unfetchablePin = RegExp(
  r"while working with @+([^:\s]+):\s*fatal: Could not parse object '([0-9a-f]+)'",
);

/// A line of a lock that holds a path on the machine that wrote it.
class HostPath {
  const HostPath(this.line, this.path, this.root);

  /// The line, counting from 1.
  final int line;

  /// The path as the lock holds it, up to the next quote or space.
  final String path;

  /// What the path is under: the description of a root given to [hostPaths].
  final String root;
}

/// The lines of [lock] (a MODULE.bazel.lock's text) that hold a path under
/// one of [roots], each a description (`the checkout`) and an absolute
/// directory, the first that matches naming the line: so give the most
/// specific first. A lock records every repository's attributes and is
/// shared, so one that holds such a path holds only on that machine.
///
/// A root matches a whole path component, plain or as a `file://` URL, with
/// `/` or `\` (written `\\` in the lock's JSON) between components. A root
/// that is empty or the filesystem root matches nothing.
List<HostPath> hostPaths(String lock, List<(String, String)> roots) {
  final patterns = [
    for (final (root, directory) in roots)
      if (_rootPattern(directory) case final pattern?) (root, pattern),
  ];
  final found = <HostPath>[];
  final lines = lock.split('\n');
  for (var i = 0; i < lines.length; i++) {
    for (final (root, pattern) in patterns) {
      if (pattern.firstMatch(lines[i]) case final match?) {
        found.add(HostPath(i + 1, match[1]!, root));
        break;
      }
    }
  }
  return found;
}

RegExp? _rootPattern(String root) {
  final parts = root
      .split(RegExp(r'[/\\]'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  // `C:` begins a Windows path; anything else begins at a separator.
  final drive = RegExp(r'^[A-Za-z]:$').hasMatch(parts.first);
  const separator = r'(?:/|\\{1,2})';
  final body = parts.map(RegExp.escape).join(separator);
  final start = drive ? '' : separator;
  return RegExp(
    '(?:^|(?<=file://)|(?<![A-Za-z0-9._~%/\\\\-]))'
    '($start$body(?:$separator[^"\'\\s]*)?)'
    '(?![A-Za-z0-9._~%-])',
  );
}

/// The workspace `.bazelrc` without the line that imports the developer's
/// gitignored `.bazelrc.user`, which can override modules, inject
/// repositories and turn the lock check off: what a lock must not record.
/// The `startup` lines of [userRc] are kept: they size the Bazel server and
/// cannot reach the lock.
String withoutUserRc(String bazelrc, {String userRc = ''}) {
  final kept = bazelrc
      .split('\n')
      .where((line) => !_userRcImport.hasMatch(line))
      .join('\n');
  final startup = [
    for (final line in userRc.split('\n'))
      if (line.trimLeft().startsWith('startup ')) line,
  ];
  return startup.isEmpty ? kept : '$kept\n${startup.join('\n')}\n';
}

final _userRcImport = RegExp(r'^\s*(try-)?import\s+\S*\.bazelrc\.user\s*$');

/// One Bazel step of a lock check or refresh.
class LockStep {
  const LockStep(this.args, this.lockfileMode);

  /// The command and its arguments.
  final List<String> args;

  /// `error` to check the lock, `update` or `refresh` to rewrite it.
  final String lockfileMode;

  String get label => 'bazel ${args.join(' ')}';
}

/// `mod deps` evaluates every module extension in the graph; a `--nobuild`
/// build evaluates the ones the targets reach, and is what fails on a stale
/// module graph entry that `mod deps` passes. Each catches stale locks the
/// other passes.
const _graphAndExtensions = [
  ['mod', 'deps'],
  ['build', '--nobuild', '--keep_going', '//...'],
];

/// The steps that check a lock and leave it alone.
final checkSteps = [
  for (final args in _graphAndExtensions) LockStep(args, 'error'),
];

/// The steps that rewrite a lock: `mod tidy` settles the module graph and
/// formats MODULE.bazel, then the checks' steps record what it left out.
final refreshSteps = [
  const LockStep(['mod', 'tidy'], 'refresh'),
  for (final args in _graphAndExtensions) LockStep(args, 'update'),
];

/// The startup options that give Bazel [rcFile] as the only rc file, if there
/// is one: no `/etc/bazel.bazelrc`, no `~/.bazelrc` and no workspace
/// `.bazelrc`, so that a lock depends on the checkout alone and not on the
/// machine that wrote it.
List<String> rcArgs(String? rcFile) => [
  '--nosystem_rc',
  '--nohome_rc',
  '--noworkspace_rc',
  if (rcFile != null) '--bazelrc=$rcFile',
];

/// The arguments to run [step] with [rcFile] as the only rc file, if there
/// is one.
List<String> bazelArgs(LockStep step, {String? rcFile}) => [
  ...rcArgs(rcFile),
  step.args.first,
  '--lockfile_mode=${step.lockfileMode}',
  '--noshow_progress',
  '--curses=no',
  '--color=no',
  ...step.args.skip(1),
];
