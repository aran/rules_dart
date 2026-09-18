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
      expect(r.rlocation('baz/templates/index.html'),
          '/runfiles/baz+1.0/templates/index.html');
    });

    test('forRepo view resolves from a different source repo', () {
      final r = Runfiles.fromState(
        directory: '/runfiles',
        repoMapping: mapping,
      );
      final libView = r.forRepo('foo+');
      expect(libView.rlocation('baz/templates/index.html'),
          '/runfiles/baz+2.0/templates/index.html');
      // Original view unchanged.
      expect(r.rlocation('baz/templates/index.html'),
          '/runfiles/baz+1.0/templates/index.html');
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
      expect(r.rlocation('baz/foo', sourceRepo: 'foo+'),
          '/runfiles/baz+2.0/foo');
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
      final r = Runfiles.fromState(
        manifest: {'real/path': '/abs/real/path'},
      );
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
      final r = Runfiles.fromState(
        manifest: {'other': '/abs/other'},
      );
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
        tmp.deleteSync(recursive: true);
      });

      // a/ holds the binary with its runfiles tree beside it; b/ is where
      // the symlink points after the "rebuild", and holds neither.
      final a = Directory('${tmp.path}${sep}a')..createSync();
      final b = Directory('${tmp.path}${sep}b')..createSync();
      File(
        Runfiles.create().rlocation('_main/dart/runfiles/$exeName'),
      ).copySync('${a.path}$sep$exeName');
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
