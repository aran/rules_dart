// Run from the workspace root: `dart pub/version_move/check_version_move.dart`.
//
// Property: a package's source repository describes the files it links in,
// whatever was fetched before. A lock that moves a package to another version
// fetches its files again, and the source repository must be made again from
// them: the version it states and the dependencies it records for planning
// are the new version's. uuid 4.5.2 depends on meta; 4.5.3 no longer does.
// rules_dart's own locks fetch no uuid, so this lock's version is the one
// built.
import 'dart:io';

const _repo = 'rules_dart++pub+dart_pub__uuid';

String _lock(String version, String sha256) =>
    '''
packages:
${_hosted('uuid', version, sha256)}
sdks:
  dart: ">=3.11.0 <4.0.0"
''';

String _hosted(String name, String version, String sha256) =>
    '''
  $name:
    dependency: "direct main"
    description:
      name: $name
      sha256: "$sha256"
      url: "https://pub.dev"
    source: hosted
    version: "$version"''';

void main() {
  final rulesDart = Directory.current.parent.parent.absolute.path;
  final temp = Directory(
    Directory.systemTemp
        .createTempSync('pub_version_move_')
        .resolveSymbolicLinksSync(),
  );
  final workspace = '${temp.path}/workspace';
  final outputBase = '${temp.path}/output_base';
  Directory(workspace).createSync();
  File('$workspace/.bazelversion')
      .writeAsStringSync(File('.bazelversion').readAsStringSync());
  File('$workspace/BUILD.bazel').writeAsStringSync('');
  File('$workspace/MODULE.bazel').writeAsStringSync('''
bazel_dep(name = "rules_dart", version = "0.0.0")
local_path_override(module_name = "rules_dart", path = "$rulesDart")

pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.from_lock(name = "deps", lock = "//:pubspec.lock")
use_repo(pub, "deps")
''');
  final lock = File('$workspace/pubspec.lock');

  // The source repository as this output base has it, after Bazel checks it
  // is up to date.
  ({String build, List<String> deps})? fetch() {
    final result = Process.runSync('bazel', [
      '--output_base=$outputBase',
      'fetch',
      '--lockfile_mode=off',
      '--noshow_progress',
      '--curses=no',
      '--repo=@@$_repo',
    ], workingDirectory: workspace);
    if (result.exitCode != 0) {
      stdout.write(result.stdout);
      stderr.write(result.stderr);
      return null;
    }
    final dir = '$outputBase/external/$_repo';
    return (
      build: File('$dir/BUILD.bazel').readAsStringSync(),
      deps: File(
        '$dir/pubspec_dependencies.txt',
      ).readAsLinesSync().where((l) => l.isNotEmpty).toList()..sort(),
    );
  }

  void expect(String version, List<String> deps) {
    final got = fetch();
    if (got == null) {
      stderr.writeln('FAILED: fetching uuid at $version');
      exitCode = 1;
    } else if (!got.build.contains('"$version"') ||
        got.deps.join(' ') != deps.join(' ')) {
      stderr.writeln(
        'FAILED: at $version, uuid\'s source repository records '
        'dependencies ${got.deps}, not $deps, and states version '
        '$version: ${got.build.contains('"$version"')}',
      );
      exitCode = 1;
    }
  }

  try {
    lock.writeAsStringSync(
      _lock(
        '4.5.2',
        'a11b666489b1954e01d992f3d601b1804a33937b5a8fe677bd26b8a9f96f96e8',
      ),
    );
    expect('4.5.2', ['crypto', 'fixnum', 'meta']);
    lock.writeAsStringSync(
      _lock(
        '4.5.3',
        '1fef9e8e11e2991bb773070d4656b7bd5d850967a2456cfc83cf47925ba79489',
      ),
    );
    expect('4.5.3', ['crypto', 'fixnum']);
  } finally {
    Process.runSync('bazel', ['--output_base=$outputBase', 'shutdown']);
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  }
  if (exitCode == 0) {
    stdout.writeln('OK: a version move remakes the source repository');
  }
}
