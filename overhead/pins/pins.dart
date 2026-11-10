/// Whether a repository uses one revision of overhead throughout: the module
/// its MODULE.bazel pins and the reusable workflows its GitHub workflows call
/// come from the same repository at the same commit.
library;

/// How MODULE.bazel brings in overhead.
sealed class OverheadPin {}

/// `git_override(module_name = "overhead", remote = ..., commit = ...)`.
class GitPin extends OverheadPin {
  GitPin(this.remote, this.commit);
  final String remote;
  final String commit;

  /// `owner/name` of a GitHub [remote], or null for another host.
  String? get gitHubRepo => RegExp(
    r'^(?:https://github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?/?$',
  ).firstMatch(remote)?[1];
}

/// `local_path_override(module_name = "overhead", path = ...)`.
class LocalPin extends OverheadPin {
  LocalPin(this.path);
  final String path;

  /// Whether [path] stays inside the repository: overhead is the
  /// repository's own, as in rules_dart.
  bool get inRepository =>
      !path.startsWith('/') && !path.split('/').contains('..');
}

/// How [moduleBazel] pins overhead, or null if it does not.
OverheadPin? overheadPin(String moduleBazel) {
  for (final call in RegExp(
    r'\b(git_override|local_path_override)\(([^)]*)\)',
  ).allMatches(moduleBazel)) {
    final attrs = {
      for (final m in RegExp(r'(\w+)\s*=\s*"([^"]*)"').allMatches(call[2]!))
        m[1]!: m[2]!,
    };
    if (attrs['module_name'] != 'overhead') continue;
    return switch (call[1]) {
      'git_override' => GitPin(attrs['remote'] ?? '', attrs['commit'] ?? ''),
      _ => LocalPin(attrs['path'] ?? ''),
    };
  }
  return null;
}

/// One `uses: <owner>/<name>/<path>@<ref>` of a reusable workflow or action.
class Uses {
  Uses(this.file, this.line, this.repo, this.ref);
  final String file;
  final int line;
  final String repo;
  final String ref;
}

/// Every remote `uses:` in [yaml], the contents of workflow [file].
List<Uses> usesIn(String file, String yaml) {
  final found = <Uses>[];
  final lines = yaml.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final m = RegExp(
      r'''^\s*(?:-\s+)?uses:\s*["']?([^/\s"']+/[^/\s@"']+)[^@\s"']*@([^\s"'#]+)''',
    ).firstMatch(lines[i]);
    if (m != null) found.add(Uses(file, i + 1, m[1]!, m[2]!));
  }
  return found;
}

/// What is inconsistent between [pin] and [uses]; empty when nothing is.
List<String> pinProblems(OverheadPin? pin, List<Uses> uses) {
  switch (pin) {
    case null:
      return [
        'MODULE.bazel does not pin overhead: add '
            'git_override(module_name = "overhead", ...) beside its bazel_dep',
      ];
    case LocalPin(:final path, inRepository: false):
      return [
        'overhead comes from the local path "$path", which nobody else has; '
            'pin it with git_override before pushing',
      ];
    case LocalPin():
      return const [];
    case GitPin(:final remote, :final commit):
      final repo = pin.gitHubRepo;
      if (repo == null) {
        return ['overhead\'s remote "$remote" is not on GitHub'];
      }
      if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
        return ['overhead\'s git_override commit "$commit" is not a full sha'];
      }
      return [
        for (final u in uses)
          if (u.repo == repo && u.ref != commit)
            '${u.file}:${u.line}: uses $repo at ${u.ref}, but MODULE.bazel '
                'pins overhead at $commit',
      ];
  }
}
