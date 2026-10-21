import 'dart:io';

class SourceFile {
  const SourceFile(this.path, this.text);

  /// The exec path, as given to Bazel actions and shown in messages.
  final String path;
  final String text;
}

/// The `.dart` files named by [paths]: a file is itself, a directory (a tree
/// artifact) its `.dart` files, sorted.
List<String> dartFiles(List<String> paths) {
  final files = <String>[];
  for (final path in paths) {
    if (Directory(path).existsSync()) {
      files.addAll(
        // Followed: a sandbox stages a tree artifact's files as links.
        Directory(path)
            .listSync(recursive: true, followLinks: true)
            .whereType<File>()
            .map((f) => f.path.replaceAll(r'\', '/'))
            .where((p) => p.endsWith('.dart'))
            .toList()
          ..sort(),
      );
    } else {
      files.add(path);
    }
  }
  return files;
}

List<SourceFile> readSources(List<String> paths) => [
  for (final path in dartFiles(paths))
    SourceFile(path, File(path).readAsStringSync()),
];
