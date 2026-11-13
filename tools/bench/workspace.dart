/// Sets up the bench's two workspaces in its scratch directory: dart-lang/pub
/// with BUILD files Gazelle writes, and a copy of `e2e/examples`, whose
/// `builders` it measures.
library;

import 'dart:io';

import 'bazel.dart';

/// What the setup needs from the rules_dart checkout and the bench's
/// runfiles.
class Sources {
  Sources({
    required this.rulesDart,
    required this.pubSource,
    required this.templates,
  });

  /// The rules_dart checkout the bench measures.
  final String rulesDart;

  /// The root of the pinned dart-lang/pub source in the runfiles.
  final String pubSource;

  /// The directory holding `pub.MODULE.bazel`, `pub.BUILD.bazel` and
  /// `bazelrc`.
  final String templates;
}

/// Lays dart-lang/pub out in [dir] and runs Gazelle over it.
Future<void> setUpPub(Sources sources, String dir, Bazel bazel) async {
  _copyTree(sources.pubSource, dir);
  String template(String name) =>
      File('${sources.templates}/$name')
          .readAsStringSync()
          .replaceAll('@RULES_DART@', sources.rulesDart);
  File('$dir/MODULE.bazel').writeAsStringSync(template('pub.MODULE.bazel'));
  File('$dir/BUILD.bazel').writeAsStringSync(template('pub.BUILD.bazel'));
  File('$dir/.bazelrc').writeAsStringSync(template('bazelrc'));
  _allowDeprecatedUses('$dir/analysis_options.yaml');
  _copyCheckoutSettings(sources.rulesDart, dir);
  await bazel.run('run', ['//:gazelle']);
}

/// One version per package: pub gets the newer `cli_util` rules_dart's own
/// tools lock, whose deprecations pub's code uses; the analysis would
/// otherwise fail on them and the analysis scenarios measure a failed build.
void _allowDeprecatedUses(String path) {
  final options = EditedFile(path);
  options.write(
    options.insertBefore(
      '    todo: ignore\n',
      '    deprecated_member_use: ignore\n',
    ),
  );
}

/// Copies `e2e/examples` to [dir], pointed at the rules_dart checkout.
Future<void> setUpCodegen(Sources sources, String dir) async {
  final from = '${sources.rulesDart}/e2e/examples';
  _copyTree(
    from,
    dir,
    skip: (rel) =>
        rel.startsWith('bazel-') ||
        rel == '.bazelrc.user' ||
        rel == 'tools/bazel',
  );
  final module = File('$dir/MODULE.bazel');
  const override = 'path = "../.."';
  final text = module.readAsStringSync();
  if (!text.contains(override)) {
    throw BenchFailure(
      '$from/MODULE.bazel no longer overrides rules_dart '
      'with `$override`; update tools/bench/workspace.dart',
    );
  }
  module.writeAsStringSync(
    text.replaceFirst(override, 'path = "${sources.rulesDart}"'),
  );
  _copyCheckoutSettings(sources.rulesDart, dir);
}

/// The checkout's Bazel version, and its untracked per-user Bazel settings
/// when it has them (`.bazelrc.user`, and the `tools/bazel` wrapper Bazelisk
/// runs), so the bench runs Bazel the way the checkout does.
void _copyCheckoutSettings(String rulesDart, String dir) {
  for (final name in ['.bazelversion', '.bazelrc.user', 'tools/bazel']) {
    final file = File('$rulesDart/$name');
    if (!file.existsSync()) continue;
    final to = File('$dir/$name')..parent.createSync(recursive: true);
    file.copySync(to.path);
  }
}

/// Copies the files under [from] to [to], following symlinks (runfiles are
/// symlinks) except into what [skip] names, by path relative to [from].
void _copyTree(String from, String to, {bool Function(String rel)? skip}) {
  void walk(String rel) {
    final dir = Directory(rel.isEmpty ? from : '$from/$rel');
    for (final entity in dir.listSync(followLinks: true)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      final childRel = rel.isEmpty ? name : '$rel/$name';
      if (skip != null && skip(childRel)) continue;
      if (entity is Directory) {
        walk(childRel);
      } else if (entity is File) {
        final dest = File('$to/$childRel')..parent.createSync(recursive: true);
        entity.copySync(dest.path);
      }
    }
  }

  walk('');
}

/// A source file the bench edits, restored when the scenario ends.
class EditedFile {
  EditedFile(this.path) : pristine = File(path).readAsStringSync();

  final String path;
  final String pristine;

  void write(String text) => File(path).writeAsStringSync(text);

  void restore() => write(pristine);

  /// [pristine] with [insert] put before [anchor], which must occur once.
  String insertBefore(String anchor, String insert) {
    final at = pristine.indexOf(anchor);
    if (at < 0 || pristine.indexOf(anchor, at + 1) >= 0) {
      throw BenchFailure(
        '$path does not contain `$anchor` exactly once; '
        'update tools/bench/scenarios.dart',
      );
    }
    return pristine.replaceRange(at, at, insert);
  }
}
