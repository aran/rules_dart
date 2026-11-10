/// Properties of the lock tool's choices: which directories are workspaces,
/// which failures pass, and what Bazel is given to read.
library;

import 'package:test/test.dart';

import '../lock_workspaces.dart';

void main() {
  group('findWorkspaces', () {
    const tracked = [
      'MODULE.bazel',
      'MODULE.bazel.lock',
      'e2e/a/MODULE.bazel',
      'e2e/a/MODULE.bazel.lock',
      'e2e/a/dep/MODULE.bazel',
      'e2e/a/dep/deeper/MODULE.bazel',
      'e2e/b/MODULE.bazel',
      'dev/MODULE.bazel',
      'overhead/MODULE.bazel',
      'overhead/.bazelversion',
      'docs/README.md',
    ];

    test('the root comes first, then every other workspace, sorted', () {
      expect(findWorkspaces(tracked), [
        '.',
        'dev',
        'e2e/a',
        'e2e/b',
        'overhead',
      ]);
    });

    test('a module inside a non-root workspace is that workspace\'s', () {
      final found = findWorkspaces(tracked);
      expect(found.where((w) => w.startsWith('e2e/a/')), isEmpty);
    });

    test('a nested module with a lock of its own is a workspace, at any '
        'depth, and holds its own overrides', () {
      final nested = [
        ...tracked,
        'e2e/a/dep/MODULE.bazel.lock',
        'e2e/a/dep/deeper/MODULE.bazel.lock',
        'e2e/a/dep/deeper/x/MODULE.bazel',
      ];
      expect(findWorkspaces(nested), [
        '.',
        'dev',
        'e2e/a',
        'e2e/a/dep',
        'e2e/a/dep/deeper',
        'e2e/b',
        'overhead',
      ]);
    });

    test('the order of the listing does not matter', () {
      expect(findWorkspaces(tracked.reversed), findWorkspaces(tracked));
    });

    test('a module the root overrides resolves with the root, unless it '
        'is also built on its own', () {
      expect(findWorkspaces(tracked, rootOverrides: {'dev', 'overhead'}), [
        '.',
        'e2e/a',
        'e2e/b',
        'overhead',
      ]);
    });

    test('untracked modules are not seen', () {
      expect(findWorkspaces(['e2e/b/MODULE.bazel']), ['e2e/b']);
    });
  });

  test('localPathOverrides normalises paths, and only reads path', () {
    const module = '''
local_path_override(
    module_name = "a",
    path = "./dev",
)
local_path_override(module_name = "b", path = "tools/../overhead")
local_path_override(module_name = "c", path = "../..")
git_override(module_name = "d", remote = "x", commit = "y")
''';
    expect(localPathOverrides(module), {'dev', 'overhead', '../..'});
  });

  group('expected failures', () {
    test('comments and blank lines are not expected text', () {
      expect(
        expectedFailureTexts('# why\n\n  conflicting versions  \n# more\nb\n'),
        ['conflicting versions', 'b'],
      );
    });

    final outcomes = [
      for (final exit in [0, 1, 2, 37])
        for (final output in ['', 'ERROR: conflicting versions in x', 'other'])
          (exit, output),
    ];

    test('a successful step passes, marked or not', () {
      for (final (exit, output) in outcomes.where((o) => o.$1 == 0)) {
        for (final expected in [
          null,
          ['conflicting versions'],
        ]) {
          expect(stepPasses(exit, output, expected), isTrue);
        }
      }
    });

    test('an unmarked workspace passes only by succeeding', () {
      for (final (exit, output) in outcomes) {
        expect(stepPasses(exit, output, null), exit == 0);
      }
    });

    test('a marked workspace passes a failure only if it prints all of it', () {
      for (final (exit, output) in outcomes.where((o) => o.$1 != 0)) {
        expect(
          stepPasses(exit, output, ['conflicting versions']),
          output.contains('conflicting versions'),
          reason: '$exit $output',
        );
        expect(
          stepPasses(exit, output, ['conflicting versions', 'mod_b']),
          isFalse,
        );
        expect(stepPasses(exit, output, []), isFalse);
      }
    });

    test('after an expected failure, a marked workspace passes any failure, '
        'and an unmarked one none', () {
      for (final (exit, output) in outcomes) {
        expect(
          stepPasses(exit, output, ['x'], afterExpectedFailure: true),
          isTrue,
        );
        expect(
          stepPasses(exit, output, null, afterExpectedFailure: true),
          exit == 0,
        );
      }
    });

    test('a success is never an expected failure', () {
      for (final (exit, output) in outcomes) {
        expect(
          failedAsExpected(exit, output, ['conflicting versions']),
          exit != 0 && output.contains('conflicting versions'),
        );
      }
    });
  });

  group('hostPaths', () {
    const roots = [
      ('the checkout', '/Users/me/src/repo'),
      ("Bazel's output root", '/Users/me/Library/Caches/bazel/_bazel_me'),
      ('the home directory', '/Users/me'),
    ];

    test('names each line holding a path under a root, with the most '
        'specific root', () {
      const lock =
          '{\n'
          '  "directory": "/Users/me/src/repo/e2e/pkg",\n'
          '  "sha256": "abc",\n'
          '  "tool": "/Users/me/Library/Caches/bazel/_bazel_me/install/x",\n'
          '  "rc": "/Users/me/.netrc"\n'
          '}\n';
      final found = hostPaths(lock, roots);
      expect(
        [for (final f in found) (f.line, f.path, f.root)],
        [
          (2, '/Users/me/src/repo/e2e/pkg', 'the checkout'),
          (
            4,
            '/Users/me/Library/Caches/bazel/_bazel_me/install/x',
            "Bazel's output root",
          ),
          (5, '/Users/me/.netrc', 'the home directory'),
        ],
      );
    });

    test('a root itself and a file:// URL match', () {
      expect(hostPaths('"/Users/me/src/repo"', roots).single.line, 1);
      expect(
        hostPaths('"url": "file:///Users/me/src/repo/a"', roots).single.path,
        '/Users/me/src/repo/a',
      );
    });

    test('a path only sharing a prefix, or under another directory, does '
        'not match', () {
      const lock =
          '"/Users/meg/x"\n'
          '"/Users/me2"\n'
          '"https://example.com/Users/me/x"\n'
          '"/opt/Users/me/x"\n'
          '"relative/Users/me"\n';
      expect(hostPaths(lock, roots), isEmpty);
    });

    test('Windows paths match with either separator, as JSON escapes them', () {
      const windows = [('the checkout', r'C:\Users\me\repo')];
      expect(hostPaths(r'"C:\\Users\\me\\repo\\pkg"', windows).single.line, 1);
      expect(hostPaths('"C:/Users/me/repo/pkg"', windows).single.line, 1);
      expect(hostPaths(r'"D:\\Users\\me\\repo"', windows), isEmpty);
    });

    test('an empty root or the filesystem root matches nothing', () {
      expect(hostPaths('"/x"\n', [('home', ''), ('home', '/')]), isEmpty);
    });
  });

  group('withoutUserRc', () {
    test('drops every import of .bazelrc.user, and only that', () {
      const rc =
          'common --foo\n'
          'try-import %workspace%/.bazelrc.user\n'
          'import %workspace%/preset.bazelrc\n'
          '  import %workspace%/e2e/.bazelrc.user  \n'
          'build --bar\n';
      expect(
        withoutUserRc(rc),
        'common --foo\nimport %workspace%/preset.bazelrc\nbuild --bar\n',
      );
    });

    test('a rc holding only the import becomes empty', () {
      expect(withoutUserRc('try-import %workspace%/.bazelrc.user\n'), '');
    });

    test('keeps the user rc\'s startup lines and nothing else of it', () {
      const user =
          'startup --host_jvm_args=-Xmx6g\n'
          'common --override_module=rules_dart=../rules_dart\n'
          'common --lockfile_mode=off\n';
      final out = withoutUserRc('common --foo\n', userRc: user);
      expect(out, contains('startup --host_jvm_args=-Xmx6g'));
      expect(out, isNot(contains('override_module')));
      expect(out, isNot(contains('lockfile_mode')));
    });
  });

  group('unfetchablePin', () {
    // What Bazel 9.3 prints when a git_override names a commit the remote
    // does not have.
    const unpushed =
        "ERROR: .../git_worker.bzl:321:9: An error occurred during the fetch "
        "of repository 'overhead+':\n"
        '   Traceback (most recent call last):\n'
        '\t\tfail("error running ...")\n'
        "Error in fail: error running 'git reset --hard "
        "699d1be2d19e7e538672b453e4e8ea391589e86e' while working with "
        '@overhead+:\n'
        "fatal: Could not parse object '699d1be2d19e7e538672b453e4e8ea391589e86e'.\n";

    test('names the repository and the commit, and says to push it', () {
      final message = unfetchablePin(unpushed);
      expect(message, contains('@overhead+'));
      expect(message, contains('699d1be2d19e7e538672b453e4e8ea391589e86e'));
      expect(message, contains('only after it is'));
    });

    test('says nothing about other failures', () {
      expect(
        unfetchablePin(
          'ERROR: MODULE.bazel.lock is no longer '
          'up-to-date',
        ),
        isNull,
      );
      expect(
        unfetchablePin(
          "error running 'git fetch' while working with "
          '@x+:\nfatal: unable to access the remote',
        ),
        isNull,
      );
    });
  });

  test('a check never writes the lock, and a refresh tidies first', () {
    expect(checkSteps.map((s) => s.lockfileMode), everyElement('error'));
    expect(refreshSteps.first.args, ['mod', 'tidy']);
    expect(
      refreshSteps.skip(1).map((s) => s.args),
      checkSteps.map((s) => s.args),
    );
  });

  test('bazelArgs reads only the given rc file', () {
    final args = bazelArgs(checkSteps.first, rcFile: '/tmp/x.bazelrc');
    expect(args.take(5), [
      '--nosystem_rc',
      '--nohome_rc',
      '--noworkspace_rc',
      '--bazelrc=/tmp/x.bazelrc',
      'mod',
    ]);
    expect(args, contains('--lockfile_mode=error'));
  });
}
