import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  group('parseRepoMapping', () {
    test('empty content yields empty map', () {
      expect(Runfiles.parseRepoMapping(''), isEmpty);
    });

    test('single row with empty source (main module)', () {
      final m = Runfiles.parseRepoMapping(',baz,baz+1.0\n');
      expect(m, {('', 'baz'): 'baz+1.0'});
    });

    test('single row with non-empty source', () {
      final m = Runfiles.parseRepoMapping('foo+,baz,baz+2.0\n');
      expect(m, {('foo+', 'baz'): 'baz+2.0'});
    });

    test('multiple rows are all parsed', () {
      final m = Runfiles.parseRepoMapping(
        ',baz,baz+1.0\n'
        'foo+,baz,baz+2.0\n'
        ',foo,foo+\n',
      );
      expect(m, {
        ('', 'baz'): 'baz+1.0',
        ('foo+', 'baz'): 'baz+2.0',
        ('', 'foo'): 'foo+',
      });
    });

    test('blank lines are skipped', () {
      final m = Runfiles.parseRepoMapping('\n,baz,baz+\n\n');
      expect(m, {('', 'baz'): 'baz+'});
    });

    test('lines with wrong column count are skipped', () {
      final m = Runfiles.parseRepoMapping(
        'too,few\n'
        ',baz,baz+\n'
        'too,many,fields,here\n',
      );
      expect(m, {('', 'baz'): 'baz+'});
    });

    test('handles missing trailing newline', () {
      final m = Runfiles.parseRepoMapping(',baz,baz+');
      expect(m, {('', 'baz'): 'baz+'});
    });
  });

  group('rlocation with repo mapping', () {
    final mapping = {
      ('', 'baz'): 'baz+1.0',
      ('foo+', 'baz'): 'baz+2.0',
      ('', '_main'): '_main',
    };

    test('main-module lookup translates apparent → canonical', () {
      final r = Runfiles.fromState(
        directory: '/runfiles',
        repoMapping: mapping,
      );
      expect(
        r.rlocation('baz/templates/index.html'),
        '/runfiles/baz+1.0/templates/index.html',
      );
    });

    test('forRepo view resolves from a different source repo', () {
      final r = Runfiles.fromState(
        directory: '/runfiles',
        repoMapping: mapping,
      );
      final libView = r.forRepo('foo+');
      expect(
        libView.rlocation('baz/templates/index.html'),
        '/runfiles/baz+2.0/templates/index.html',
      );
      // Original view unchanged.
      expect(
        r.rlocation('baz/templates/index.html'),
        '/runfiles/baz+1.0/templates/index.html',
      );
    });

    test('apparent name absent from mapping → path used verbatim', () {
      final r = Runfiles.fromState(
        directory: '/runfiles',
        repoMapping: mapping,
      );
      expect(r.rlocation('unknown/foo'), '/runfiles/unknown/foo');
    });

    test('empty mapping → all paths used verbatim', () {
      final r = Runfiles.fromState(directory: '/runfiles');
      expect(r.rlocation('baz/foo'), '/runfiles/baz/foo');
      expect(r.rlocation('_main/foo'), '/runfiles/_main/foo');
    });

    test('single-segment path (no slash) is handled', () {
      final r = Runfiles.fromState(
        directory: '/runfiles',
        repoMapping: mapping,
      );
      expect(r.rlocation('baz'), '/runfiles/baz+1.0');
      expect(r.rlocation('unknown'), '/runfiles/unknown');
    });

    test('sourceRepo override on rlocation wins over default', () {
      final r = Runfiles.fromState(
        directory: '/runfiles',
        repoMapping: mapping,
      );
      expect(
        r.rlocation('baz/foo', sourceRepo: 'foo+'),
        '/runfiles/baz+2.0/foo',
      );
    });

    test('defaultSourceRepo set via fromState is used when no override', () {
      final r = Runfiles.fromState(
        directory: '/runfiles',
        repoMapping: mapping,
        defaultSourceRepo: 'foo+',
      );
      expect(r.rlocation('baz/foo'), '/runfiles/baz+2.0/foo');
    });
  });

  group('rlocation manifest vs directory', () {
    test('manifest hit returns manifest-mapped path', () {
      final r = Runfiles.fromState(manifest: {'real/path': '/abs/real/path'});
      expect(r.rlocation('real/path'), '/abs/real/path');
    });

    test('manifest takes priority over directory when both present', () {
      final r = Runfiles.fromState(
        directory: '/dir',
        manifest: {'p': '/abs/p'},
      );
      expect(r.rlocation('p'), '/abs/p');
    });

    test('directory fallback when manifest miss', () {
      final r = Runfiles.fromState(
        directory: '/dir',
        manifest: {'other': '/abs/other'},
      );
      expect(r.rlocation('p'), '/dir/p');
    });

    test('manifest-only with miss and no directory throws', () {
      final r = Runfiles.fromState(manifest: {'other': '/abs/other'});
      expect(() => r.rlocation('p'), throwsStateError);
    });

    test('repo mapping is applied before manifest lookup', () {
      final r = Runfiles.fromState(
        manifest: {'baz+1.0/foo': '/abs/baz/foo'},
        repoMapping: {('', 'baz'): 'baz+1.0'},
      );
      expect(r.rlocation('baz/foo'), '/abs/baz/foo');
    });
  });

  group('environment', () {
    test('names what was found, for a child process to find it too', () {
      expect(
        Runfiles.fromState(directory: '/dir', manifestPath: '/m').environment,
        {'RUNFILES_DIR': '/dir', 'RUNFILES_MANIFEST_FILE': '/m'},
      );
      expect(Runfiles.fromState(manifest: const {}).environment, isEmpty);
    });

    test('is absolute, so it holds after the child changes directory', () {
      for (final path in Runfiles.create().environment.values) {
        expect(File(path).isAbsolute, isTrue, reason: path);
      }
    });
  });

  group('create() probing next to the executable', () {
    // `./bazel-bin/pkg/tool` reaches the binary through a symlink that the
    // next build in another configuration repoints. A Runfiles created
    // before that must still find its files afterwards.
    test('survives a symlink on the executable path being repointed', () async {
      final sep = Platform.pathSeparator;
      final exeName = Platform.isWindows ? 'create_probe.exe' : 'create_probe';
      final tmp = Directory.systemTemp.createTempSync('runfiles_create');
      final current = '${tmp.path}${sep}current';
      addTearDown(() {
        if (FileSystemEntity.isLinkSync(current)) Link(current).deleteSync();
        return _deleteRunExecutables(tmp);
      });

      // a/ holds the binary with its runfiles tree beside it; b/ is where
      // the symlink points after the "rebuild", and holds neither.
      final a = Directory('${tmp.path}${sep}a')..createSync();
      final b = Directory('${tmp.path}${sep}b')..createSync();
      File(Runfiles.create().rlocation('_main/dart/runfiles/$exeName'))
          .copySync('${a.path}$sep$exeName');
      File('${a.path}$sep$exeName.runfiles${sep}_main${sep}data.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('found');
      _pointLink(current, a.path);

      final process = await Process.start(
        '$current$sep$exeName',
        const [],
        environment: Map.of(Platform.environment)
          ..remove('RUNFILES_DIR')
          ..remove('RUNFILES_MANIFEST_FILE'),
        includeParentEnvironment: false,
      );
      addTearDown(process.kill);
      final stderr = process.stderr.transform(utf8.decoder).join();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );

      if (!await lines.moveNext()) fail('probe exited: ${await stderr}');
      expect(lines.current, 'ready');

      _pointLink(current, b.path);
      await process.stdin.close();

      final rest = <String>[];
      while (await lines.moveNext()) {
        rest.add(lines.current);
      }
      expect(await process.exitCode, 0, reason: await stderr);
      expect(rest, ['found']);
    });
  });

  group('rlocation through Runfiles.create() in every discovery mode', () {
    // Property: `rlocation` resolves every path the official runfiles
    // libraries (Java, Python, C++, Go) resolve, whichever way Bazel handed
    // the runfiles over: RUNFILES_DIR, RUNFILES_MANIFEST_FILE, or a MANIFEST
    // inside RUNFILES_DIR (all that `--noenable_runfiles` leaves there).
    // Each case runs a real `Runfiles.create()` in a child process, because
    // manifest parsing is only reachable from the environment.
    late Directory tmp;
    late String probe;
    final sep = Platform.pathSeparator;

    setUpAll(() {
      final exe = Platform.isWindows ? 'lookup_probe.exe' : 'lookup_probe';
      probe = Runfiles.create().rlocation('_main/dart/runfiles/$exe');
    });
    setUp(() => tmp = Directory.systemTemp.createTempSync('runfiles_modes'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File write(String rel, String content) => File('${tmp.path}$sep$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    /// Runs `lookup_probe` with exactly [env] and returns one line per path.
    Future<List<String>> lookup(
      Map<String, String> env,
      List<String> paths,
    ) async {
      final r = await Process.run(
        probe,
        paths,
        environment: env,
        includeParentEnvironment: false,
      );
      expect(r.exitCode, 0, reason: 'create() failed: ${r.stderr}');
      return const LineSplitter()
          .convert(r.stdout as String)
          .map((l) => jsonDecode(l) as String)
          .toList();
    }

    group('RUNFILES_MANIFEST_FILE', () {
      test('exact entry resolves', () async {
        final m = write('m', '_main/a.txt /real/a.txt\n');
        expect(
          await lookup({'RUNFILES_MANIFEST_FILE': m.path}, ['_main/a.txt']),
          ['/real/a.txt'],
        );
      });

      test('a file inside a tree artifact resolves through the directory '
          'entry (Java/Python/C++/Go prefix walk)', () async {
        final m = write('m', '_main/pkg/out.dir /real/out.dir\n');
        expect(
          await lookup(
            {'RUNFILES_MANIFEST_FILE': m.path},
            ['_main/pkg/out.dir/f.txt', '_main/pkg/out.dir/sub/deeper/g.txt'],
          ),
          ['/real/out.dir/f.txt', '/real/out.dir/sub/deeper/g.txt'],
        );
      });

      test('an exact entry beats a shorter prefix, the nearest prefix beats '
          'a farther one', () async {
        final m = write(
          'm',
          '_main/out /real/outer\n'
              '_main/out/sub /real/inner\n'
              '_main/out/sub/x.txt /real/exact.txt\n',
        );
        expect(
          await lookup(
            {'RUNFILES_MANIFEST_FILE': m.path},
            ['_main/out/sub/x.txt', '_main/out/sub/y.txt', '_main/out/z.txt'],
          ),
          ['/real/exact.txt', '/real/inner/y.txt', '/real/outer/z.txt'],
        );
      });

      test('a prefix must end on a path-segment boundary', () async {
        final m = write('m', '_main/out /real/out\n');
        expect(
          await lookup(
            {'RUNFILES_MANIFEST_FILE': m.path},
            ['_main/outer/f.txt'],
          ),
          ['ERROR'],
        );
      });

      test(
        'the prefix walk also works when a runfiles directory is set too',
        () async {
          final m = write('m', '_main/out.dir /real/out.dir\n');
          final dir = Directory('${tmp.path}${sep}rf')..createSync();
          expect(
            await lookup(
              {'RUNFILES_MANIFEST_FILE': m.path, 'RUNFILES_DIR': dir.path},
              ['_main/out.dir/f.txt'],
            ),
            ['/real/out.dir/f.txt'],
          );
        },
      );

      test('repo mapping applies before the prefix walk', () async {
        final mapping = write('mapping', ',baz,baz+\n');
        final m = write(
          'm',
          '_repo_mapping ${mapping.path}\n'
              'baz+/out.dir /real/out.dir\n',
        );
        expect(
          await lookup(
            {'RUNFILES_MANIFEST_FILE': m.path},
            ['baz/out.dir/f.txt'],
          ),
          ['/real/out.dir/f.txt'],
        );
      });

      test(
        'a target path containing spaces survives (unescaped legacy line)',
        () async {
          final m = write('m', '_main/a.txt /real/with space/a.txt\n');
          expect(
            await lookup({'RUNFILES_MANIFEST_FILE': m.path}, ['_main/a.txt']),
            ['/real/with space/a.txt'],
          );
        },
      );

      // Bazel writes " <escaped path> <escaped target>" when either holds a
      // space, newline or backslash: \s = space, \n = newline, \b = backslash.
      test('escaped line: spaces in the runfiles path', () async {
        final m = write('m', ' _main/my\\sfile.txt /real/file.txt\n');
        expect(
          await lookup(
            {'RUNFILES_MANIFEST_FILE': m.path},
            ['_main/my file.txt'],
          ),
          ['/real/file.txt'],
        );
      });

      test('escaped line: spaces in the target', () async {
        final m = write('m', ' _main/a.txt /real/my\\sdir/a.txt\n');
        expect(
          await lookup({'RUNFILES_MANIFEST_FILE': m.path}, ['_main/a.txt']),
          ['/real/my dir/a.txt'],
        );
      });

      test('escaped line: newline and backslash in path and target', () async {
        final m = write('m', ' _main/a\\nb\\bc.txt /real/x\\ny\\bz.txt\n');
        expect(
          await lookup(
            {'RUNFILES_MANIFEST_FILE': m.path},
            ['_main/a\nb\\c.txt'],
          ),
          ['/real/x\ny\\z.txt'],
        );
      });

      test('escaped line in a tree artifact prefix walk', () async {
        final m = write('m', ' _main/my\\sout.dir /real/my\\sout.dir\n');
        expect(
          await lookup(
            {'RUNFILES_MANIFEST_FILE': m.path},
            ['_main/my out.dir/f.txt'],
          ),
          ['/real/my out.dir/f.txt'],
        );
      });

      test('an escaped line does not break the lines around it', () async {
        final m = write(
          'm',
          '_main/a.txt /real/a.txt\n'
              ' _main/b\\sc.txt /real/bc.txt\n'
              '_main/d.txt /real/d.txt\n',
        );
        expect(
          await lookup(
            {'RUNFILES_MANIFEST_FILE': m.path},
            ['_main/a.txt', '_main/b c.txt', '_main/d.txt'],
          ),
          ['/real/a.txt', '/real/bc.txt', '/real/d.txt'],
        );
      });
    });

    group('RUNFILES_DIR only', () {
      test('plain directory resolves by joining', () async {
        final dir = Directory('${tmp.path}${sep}rf')..createSync();
        expect(await lookup({'RUNFILES_DIR': dir.path}, ['_main/a.txt']), [
          '${dir.path}/_main/a.txt',
        ]);
      });

      test('a MANIFEST inside the directory is used (all that is left under '
          '--noenable_runfiles)', () async {
        final dir = Directory('${tmp.path}${sep}rf')..createSync();
        File('${dir.path}${sep}MANIFEST')
            .writeAsStringSync('_main/a.txt /real/a.txt\n');
        expect(await lookup({'RUNFILES_DIR': dir.path}, ['_main/a.txt']), [
          '/real/a.txt',
        ]);
      });

      test('a tree artifact file resolves through the MANIFEST inside the '
          'directory', () async {
        final dir = Directory('${tmp.path}${sep}rf')..createSync();
        File('${dir.path}${sep}MANIFEST')
            .writeAsStringSync('_main/pkg/out.dir /real/out.dir\n');
        expect(
          await lookup({'RUNFILES_DIR': dir.path}, ['_main/pkg/out.dir/f.txt']),
          ['/real/out.dir/f.txt'],
        );
      });

      test('an escaped MANIFEST inside the directory is understood', () async {
        final dir = Directory('${tmp.path}${sep}rf')..createSync();
        File('${dir.path}${sep}MANIFEST')
            .writeAsStringSync(' _main/a\\sb.txt /real/a\\sb.txt\n');
        expect(await lookup({'RUNFILES_DIR': dir.path}, ['_main/a b.txt']), [
          '/real/a b.txt',
        ]);
      });
    });

    group('next to the executable, with no variable set', () {
      // What `bazel run` leaves a plain executable on Windows, whose default
      // is `--noenable_runfiles`: no variable, and a manifest beside it or
      // inside a runfiles directory that holds nothing else.
      // One copy of the probe for every case, each putting beside it what
      // it needs and removing it after: Windows scans a new executable when
      // it first runs, which on a loaded machine takes seconds.
      late Directory home;
      late String exe;
      setUpAll(() {
        home = Directory.systemTemp.createTempSync('runfiles_next_to');
        // rlocation returns the manifest's target as written, and Bazel
        // writes those with forward slashes on Windows too.
        exe = '${home.path}$sep${Uri.file(probe).pathSegments.last}';
        File(probe).copySync(exe);
      });
      tearDown(() {
        for (final beside in [
          File('$exe.runfiles_manifest'),
          Directory('$exe.runfiles'),
        ]) {
          if (beside.existsSync()) beside.deleteSync(recursive: true);
        }
      });
      tearDownAll(() => _deleteRunExecutables(home));

      // Neither runfiles variable, but the rest of a normal environment:
      // Windows refuses to start a process with an empty one.
      final noVariable = Map.of(Platform.environment)
        ..remove('RUNFILES_DIR')
        ..remove('RUNFILES_MANIFEST_FILE');

      test('a manifest beside it is used', () async {
        File('$exe.runfiles_manifest')
            .writeAsStringSync('_main/a.txt /real/a.txt\n');
        final r = await Process.run(
          exe,
          ['_main/a.txt'],
          environment: noVariable,
          includeParentEnvironment: false,
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(jsonDecode((r.stdout as String).trim()), '/real/a.txt');
      });

      test('a MANIFEST inside the runfiles directory is used when it is all '
          'the directory holds', () async {
        File('$exe.runfiles${sep}MANIFEST')
          ..createSync(recursive: true)
          ..writeAsStringSync('_main/a.txt /real/a.txt\n');
        final r = await Process.run(
          exe,
          ['_main/a.txt'],
          environment: noVariable,
          includeParentEnvironment: false,
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(jsonDecode((r.stdout as String).trim()), '/real/a.txt');
      });

      test(
        'a runfiles directory with no manifest resolves by joining',
        () async {
          final dir = Directory('$exe.runfiles')..createSync();
          final r = await Process.run(
            exe,
            ['_main/a.txt'],
            environment: noVariable,
            includeParentEnvironment: false,
          );
          expect(r.exitCode, 0, reason: '${r.stderr}');
          expect(
            jsonDecode((r.stdout as String).trim()),
            '${dir.resolveSymbolicLinksSync()}/_main/a.txt',
          );
        },
      );

      test('with none, create() fails naming where it looked', () async {
        final r = await Process.run(
          exe,
          ['_main/a.txt'],
          environment: noVariable,
          includeParentEnvironment: false,
        );
        expect(r.exitCode, isNot(0));
        expect(r.stderr, contains('$exe.runfiles_manifest'));
        expect(r.stderr, contains('$exe.runfiles'));
      });
    });

    group('every official library agrees on these', () {
      test('an absolute path is returned unchanged', () async {
        final dir = Directory('${tmp.path}${sep}rf')..createSync();
        final abs = '${tmp.path}${sep}elsewhere.txt';
        expect(await lookup({'RUNFILES_DIR': dir.path}, [abs]), [abs]);
      });

      // Java throws, Python raises, Go returns an error, C++ returns "":
      // all refuse. Dart's contract is a throw (or anything but a path).
      test('a path with a `..` or `.` segment is refused', () async {
        final dir = Directory('${tmp.path}${sep}rf')..createSync();
        expect(
          await lookup(
            {'RUNFILES_DIR': dir.path},
            ['_main/../etc/passwd', '_main/./a.txt'],
          ),
          ['ERROR', 'ERROR'],
        );
      });
    });
  });
}

/// Points the directory symlink at [link] to [target], replacing any
/// existing one. Windows gets a junction — what Bazel makes `bazel-bin`
/// there, and creatable without symlink privilege.
void _pointLink(String link, String target) {
  if (FileSystemEntity.isLinkSync(link)) Link(link).deleteSync();
  if (!Platform.isWindows) {
    Link(link).createSync(target);
    return;
  }
  final result = Process.runSync('cmd', ['/c', 'mklink', '/J', link, target]);
  if (result.exitCode != 0) {
    throw StateError('mklink /J $link $target failed: ${result.stderr}');
  }
}

/// Deletes [directory], which holds a copied executable that has just run.
///
/// Windows can refuse for a while to delete one, though its process has
/// exited and holds nothing: on a loaded Windows VM no process held a handle
/// in the directory when it was refused. It is waited for.
Future<void> _deleteRunExecutables(Directory directory) async {
  for (var tries = 1; ; tries++) {
    try {
      directory.deleteSync(recursive: true);
      return;
    } on PathAccessException {
      if (!Platform.isWindows || tries == 100) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
