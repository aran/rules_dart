import 'dart:io';

/// The modules a release of [repo] publishes, in the order of `moduleRoots`
/// in its `.bcr/config.yml`: the module at each root's MODULE.bazel. A
/// repository whose config names no roots publishes the module at its root,
/// as publish-to-bcr does.
List<String> releasedModules(String repo) {
  final config = File('$repo/.bcr/config.yml');
  final roots = moduleRoots(
    config.existsSync() ? config.readAsStringSync() : '',
  );
  return [
    for (final root in roots)
      if (File('$repo/$root/MODULE.bazel') case final file
          when file.existsSync())
        moduleName(file.readAsStringSync()) ??
            (throw FormatException(
              'no module(name = ...) in $root/MODULE.bazel',
            ))
      else
        throw FormatException(
          '.bcr/config.yml: module root $root has no MODULE.bazel',
        ),
  ];
}

/// The `moduleRoots` of a `.bcr/config.yml`, written as a flow sequence
/// (`moduleRoots: [".", "gazelle"]`) or a block one (`- gazelle` lines); `.`
/// when there is no such key. Any other form is an error, not a guess.
List<String> moduleRoots(String config) {
  final lines = config.split('\n');
  final key = RegExp(r'^moduleRoots\s*:(.*)$');
  for (var i = 0; i < lines.length; i++) {
    final match = key.firstMatch(lines[i].trimRight());
    if (match == null) continue;
    final rest = _uncommented(match[1]!).trim();
    if (rest.startsWith('[')) {
      if (!rest.endsWith(']')) {
        throw const FormatException(
          '.bcr/config.yml: moduleRoots must be a one-line [...] or a - list',
        );
      }
      final inner = rest.substring(1, rest.length - 1).trim();
      return _nonEmpty([
        if (inner.isNotEmpty)
          for (final item in inner.split(',')) _scalar(item),
      ]);
    }
    if (rest.isNotEmpty) {
      throw const FormatException(
        '.bcr/config.yml: moduleRoots must be a one-line [...] or a - list',
      );
    }
    final roots = <String>[];
    for (final line in lines.skip(i + 1)) {
      final item = _uncommented(line).trim();
      if (item.isEmpty) continue;
      if (!item.startsWith('- ') && item != '-') break;
      roots.add(_scalar(item.substring(1)));
    }
    return _nonEmpty(roots);
  }
  return const ['.'];
}

List<String> _nonEmpty(List<String> roots) {
  if (roots.isEmpty) {
    throw const FormatException('.bcr/config.yml: moduleRoots is empty');
  }
  return roots;
}

/// [line] without a `#` comment; module roots never contain `#`.
String _uncommented(String line) {
  final hash = line.indexOf('#');
  return hash < 0 ? line : line.substring(0, hash);
}

/// A plain, single- or double-quoted YAML scalar holding a directory.
String _scalar(String item) {
  final text = item.trim();
  final quoted = RegExp(r'''^(["'])(.*)\1$''').firstMatch(text);
  final value = quoted != null ? quoted[2]! : text;
  if (value.isEmpty || RegExp(r'''["'\[\]{},:]''').hasMatch(value)) {
    throw FormatException('.bcr/config.yml: not a module root: $text');
  }
  return value;
}

/// The name in the `module()` call of [moduleBazel], or null.
String? moduleName(String moduleBazel) => RegExp(
  r'^module\(\s*name\s*=\s*"([^"]+)"',
  multiLine: true,
).firstMatch(moduleBazel)?[1];

/// What the release notes open with: the `bazel_dep` of each of [modules] at
/// [version].
String installSnippet(List<String> modules, String version) =>
    '''
Add to your `MODULE.bazel` file:

```starlark
${modules.map((m) => 'bazel_dep(name = "$m", version = "$version")').join('\n')}
```

''';
