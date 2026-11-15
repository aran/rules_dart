// Run from the workspace root: `dart pub/vendor/check_vendor.dart`.
//
// Property: `bazel vendor` makes a pub package vendored as it would be
// fetched. A hosted or git package's source repository links its files in
// from another repository, so its links must survive vendoring: none may
// name the output base that vendored it, and a build from the vendored
// directory, in a new output base, with that output base deleted, must build
// the packages from the vendored files. The build is the new output base's
// first, so no repository a vendored source repository links into is made
// before Bazel reads through the links unless the source repository asks for
// it.
import 'dart:io';

const _targets = ['//pub/lock:app', '//pub/git:git_packages_test'];

// The source repositories of the packages those targets build: one hosted
// package and one git package.
const _sourceRepos = [
  'rules_dart++pub+dart_pub__collection',
  'rules_dart++pub+dart_pub__git_root',
];

void main() {
  final temp = Directory(
    Directory.systemTemp
        .createTempSync('pub_vendor_')
        .resolveSymbolicLinksSync(),
  );
  final vendor = '${temp.path}/vendor';
  final vendoring = '${temp.path}/output_base_vendoring';
  final building = '${temp.path}/output_base_building';
  // Repositories are made in the output base, not taken from the shared
  // contents cache, whose copies would outlive the vendoring output base.
  const common = ['--repo_contents_cache=', '--noshow_progress', '--curses=no'];

  bool run(String what, List<String> args) {
    final result = Process.runSync('bazel', args);
    if (result.exitCode == 0) return true;
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    stderr.writeln('FAILED: $what');
    exitCode = 1;
    return false;
  }

  try {
    try {
      if (!run('bazel vendor', [
        '--output_base=$vendoring',
        'vendor',
        '--vendor_dir=$vendor',
        ...common,
        ..._targets,
      ])) {
        return;
      }
    } finally {
      Process.runSync('bazel', ['--output_base=$vendoring', 'shutdown']);
    }

    // No link in a vendored source repository names an absolute path, which
    // would be the vendoring output base: each goes through the vendored
    // directory, which Bazel points at whichever output base builds.
    for (final repo in _sourceRepos) {
      final dir = Directory('$vendor/$repo');
      if (!dir.existsSync()) {
        stderr.writeln('FAILED: $repo was not vendored');
        exitCode = 1;
        continue;
      }
      final links = dir.listSync(followLinks: false).whereType<Link>();
      if (links.isEmpty) {
        stderr.writeln('FAILED: $repo links nothing in');
        exitCode = 1;
      }
      for (final link in links) {
        final target = link.targetSync();
        if (Link(target).isAbsolute) {
          stderr.writeln('FAILED: ${link.path} names $target');
          exitCode = 1;
        }
      }
    }

    Process.runSync('chmod', ['-R', 'u+w', vendoring]);
    Directory(vendoring).deleteSync(recursive: true);

    try {
      run('a build from the vendored directory', [
        '--output_base=$building',
        'test',
        '--vendor_dir=$vendor',
        '--test_output=errors',
        ...common,
        ..._targets,
      ]);
    } finally {
      Process.runSync('bazel', ['--output_base=$building', 'shutdown']);
    }
  } finally {
    Process.runSync('chmod', ['-R', 'u+w', temp.path]);
    temp.deleteSync(recursive: true);
  }
  if (exitCode == 0) stdout.writeln('OK: vendored pub packages build');
}
