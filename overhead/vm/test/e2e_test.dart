import 'dart:convert';
import 'dart:io';

import 'package:overhead_vm/e2e.dart';
import 'package:test/test.dart';

void main() {
  group('E2eOptions.parse', () {
    test('defaults', () {
      final o = E2eOptions.parse(['vm-a']);
      expect(o.vm, 'vm-a');
      expect(o.windows, isFalse);
      expect(o.keepGoing, isFalse);
      expect(o.remoteCache, isNull);
      expect(o.folders, isNull);
      expect(o.repoOptions, isEmpty);
    });

    test('every option, in any order', () {
      final o = E2eOptions.parse([
        '--windows',
        '--folders=./e2e/smoke/, .,e2e/basics',
        'vm-b',
        '--keep-going',
        '--remote-cache=https://storage.googleapis.com/bucket',
      ]);
      expect(o.vm, 'vm-b');
      expect(o.windows, isTrue);
      expect(o.keepGoing, isTrue);
      expect(o.remoteCache, 'https://storage.googleapis.com/bucket');
      expect(o.folders, ['e2e/smoke', '.', 'e2e/basics']);
    });

    test("the repository's own options", () {
      final o = E2eOptions.parse(
        ['vm', '--rules-dart=../rules_dart'],
        repoOptions: {'rules-dart'},
      );
      expect(o.repoOptions, {'rules-dart': '../rules_dart'});
    });

    for (final (args, problem) in [
      (<String>[], 'no VM named'),
      (['a', 'b'], 'one VM name'),
      (['vm', '--rules-dart=x'], 'unknown option'),
      (['vm', '--remote-cache'], 'needs a value'),
      (['vm', '--windows=yes'], 'unknown option'),
      (['vm', '-x'], 'unknown option'),
    ]) {
      test('refuses $args', () {
        expect(
          () => E2eOptions.parse(args),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(problem),
            ),
          ),
        );
      });
    }
  });

  group('homeBazelrc', () {
    test('Linux, no remote cache', () {
      expect(homeBazelrc(windows: false), '''
startup --max_idle_secs=900
startup --host_jvm_args=-Xmx4g
common --disk_cache=~/.cache/bazel-disk
common --experimental_disk_cache_gc_max_size=20G
common --experimental_disk_cache_gc_max_age=7d
common --keep_going
''');
    });

    test('Windows, with a remote cache', () {
      final rc = homeBazelrc(windows: true, remoteCache: 'https://c/b');
      expect(rc, contains('common --disk_cache=C:/bdc\n'));
      expect(rc, contains('gc_max_size=40G\n'));
      expect(
        rc,
        endsWith(
          'common --remote_cache=https://c/b\n'
          'common --google_default_credentials\n',
        ),
      );
    });
  });

  group('linuxCommand', () {
    String decoded(String command) => utf8.decode(
      base64.decode(RegExp(r'echo (\S+) \| base64').firstMatch(command)![1]!),
    );

    test('a script, in its folder', () {
      final c = linuxCommand(
        E2eItem.script('e2e/x', 'out=\$(bazel build //...)\necho "\$out"'),
        r'$HOME/src/r',
      );
      expect(c, startsWith("bash -lc 'cd \"\$HOME/src/r/e2e/x\" && "));
      expect(c, endsWith("echo E2E_EXIT=\$?'"));
      expect(c, contains('bash -e -o pipefail /tmp/e2e_step.sh'));
      expect(decoded(c), 'out=\$(bazel build //...)\necho "\$out"');
    });

    test('Bazel, in the root, its arguments quoted', () {
      final c = linuxCommand(
        E2eItem.bazel('.', ['test', '--test_env=A=b c', '//...']),
        r'$HOME/src/r',
      );
      expect(c, contains('cd "\$HOME/src/r" &&'));
      expect(decoded(c), "bazel test '--test_env=A=b c' //...");
    });
  });

  group('windowsCommand', () {
    test('Bazel, with a short output base of its folder', () {
      final c = windowsCommand(
        E2eItem.bazel('e2e/x', ['test', '//...']),
        r'C:\src\r',
      );
      expect(
        c,
        'cmd /v:on /c "cd /d C:\\src\\r\\e2e\\x && '
        'bazel --output_base=C:/b/${folderHash('e2e/x')} test //... & '
        'echo E2E_EXIT=!errorlevel!"',
      );
    });

    test('refuses a script', () {
      expect(
        () => windowsCommand(E2eItem.script('.', 'true'), r'C:\src\r'),
        throwsArgumentError,
      );
    });
  });

  group('stopCommand', () {
    test("Windows: ends the folder's server tree by its pid file", () {
      expect(
        stopCommand(
          E2eItem.bazel('e2e/x', ['test']),
          r'C:\src\r',
          windows: true,
        ),
        'cmd /c "if exist C:\\b\\${folderHash('e2e/x')}\\server\\server.pid.txt '
        'for /f %p in (C:\\b\\${folderHash('e2e/x')}\\server\\server.pid.txt) '
        'do taskkill /f /t /pid %p"',
      );
    });

    test(
      "Linux: kills the server's process group in its default output base",
      () {
        final c = stopCommand(
          E2eItem.bazel('e2e/x', ['test']),
          r'$HOME/src/r',
          windows: false,
        );
        final script = utf8.decode(
          base64.decode(RegExp(r'echo (\S+) \| base64').firstMatch(c)![1]!),
        );
        expect(script, contains(r'ws=$(cd "$HOME/src/r/e2e/x" && pwd -P)'));
        expect(script, contains(r'md5sum | cut -c1-32'));
        expect(script, contains(r'kill -9 -- "-$pid"'));
        expect(script, endsWith('! kill -0 "\$pid" 2>/dev/null\n'));
      },
    );
  });

  test('an item times out after 30 minutes unless it says otherwise', () {
    expect(E2eItem.bazel('.', ['test']).timeout, const Duration(minutes: 30));
    expect(
      E2eItem.script('.', 'x', timeout: const Duration(hours: 2)).timeout,
      const Duration(hours: 2),
    );
  });

  test('folderHash is short, stable and tells folders apart', () {
    expect(folderHash('.'), hasLength(8));
    expect(folderHash('e2e/a'), folderHash('e2e/a'));
    expect(folderHash('e2e/a'), isNot(folderHash('e2e/b')));
  });

  test('parseExit takes the last mark, and says when there is none', () {
    expect(parseExit('E2E_EXIT=3\nlog E2E_EXIT=4\n'), 4);
    expect(parseExit('E2E_EXIT=-2'), -2);
    expect(parseExit('nothing'), noExitMark);
  });

  test('passExitCodes defaults to 0', () {
    expect(E2eItem.bazel('.', ['test']).passExitCodes, {0});
    expect(E2eItem.bazel('.', ['test'], passExitCodes: {0, 4}).passExitCodes, {
      0,
      4,
    });
  });

  test(
    'packageCommittedTree packs HEAD as committed, export-ignore and all',
    () {
      final dir = Directory.systemTemp.createTempSync('pack_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = '${dir.path}/repo';
      Directory('$repo/e2e').createSync(recursive: true);
      void git(List<String> args) {
        final r = Process.runSync('git', ['-C', repo, ...args]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }

      git(['init', '-q']);
      File('$repo/.gitattributes')
          .writeAsStringSync('e2e export-ignore\nsubst.txt export-subst\n');
      File('$repo/subst.txt').writeAsStringSync(r'$Format:%H$');
      File('$repo/e2e/日本語.txt').writeAsStringSync('committed');
      File('$repo/a.txt').writeAsStringSync('committed');
      File('$repo/lf.txt').writeAsStringSync('a\nb\n');
      git(['add', '-A']);
      git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'c']);
      File('$repo/a.txt').writeAsStringSync('changed');
      File('$repo/untracked.txt').writeAsStringSync('x');

      final out = '${dir.path}/out';
      Directory(out).createSync();
      expect(readTar(File(packageCommittedTree(repo, out))), {
        '.gitattributes': 'e2e export-ignore\nsubst.txt export-subst\n',
        'a.txt': 'committed',
        'lf.txt': 'a\nb\n',
        'e2e/日本語.txt': 'committed',
        'subst.txt': r'$Format:%H$',
      });
    },
  );
}

/// The regular files of the tar at [file], by path, as UTF-8 text: read here
/// rather than by a host `tar`, which on Windows reads names in the ANSI code
/// page.
Map<String, String> readTar(File file) {
  final bytes = file.readAsBytesSync();
  String field(int at, int length) {
    final f = bytes.sublist(at, at + length);
    final end = f.indexOf(0);
    return utf8.decode(end < 0 ? f : f.sublist(0, end));
  }

  final files = <String, String>{};
  String? paxPath;
  for (var at = 0; at + 512 <= bytes.length && bytes[at] != 0;) {
    final size = int.parse(field(at + 124, 12).trim(), radix: 8);
    final type = field(at + 156, 1);
    final prefix = field(at + 345, 155);
    final name = paxPath ?? (prefix.isEmpty ? '' : '$prefix/') + field(at, 100);
    final body = bytes.sublist(at + 512, at + 512 + size);
    paxPath = null;
    if (type == 'x') {
      paxPath = RegExp(r'\d+ path=(.*)\n').firstMatch(utf8.decode(body))?[1];
    } else if (type == '0' || type == '') {
      files[name] = utf8.decode(body);
    }
    at += 512 + (size + 511) ~/ 512 * 512;
  }
  return files;
}
