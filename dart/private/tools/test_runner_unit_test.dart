import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'test_runner.dart' as launcher;

/// The pure parts of the `dart_test` launcher, in process: `test_runner_test`
/// runs the real launcher only for what a process shows.
void main() {
  group('TagSelection', () {
    launcher.TagSelection of(
      Map<String, dynamic> config, [
      Map<String, String> environment = const {},
    ]) => launcher.TagSelection.of(config, environment);

    final target = {
      'include_tags': ['unit || integration'],
      'exclude_tags': ['slow'],
    };

    test('the target\'s selection is the runner\'s arguments', () {
      final selection = of(target);
      expect(selection.fixed, isTrue);
      expect(selection.perRun, isFalse);
      expect(selection.arguments, [
        '--tags=unit || integration',
        '--exclude-tags=slow',
      ]);
    });

    test('a run\'s include is added to the target\'s, to be intersected', () {
      final selection = of(target, {'DART_TEST_TAGS': 'integration'});
      expect(selection.perRun, isTrue);
      expect(selection.arguments, [
        '--tags=unit || integration',
        '--tags=integration',
        '--exclude-tags=slow',
      ]);
    });

    test('a run\'s include is passed as `dart test --tags` takes it', () {
      expect(of(target, {'DART_TEST_TAGS': 'suite_tag,unit'}).arguments, [
        '--tags=unit || integration',
        '--tags=suite_tag,unit',
        '--exclude-tags=slow',
      ]);
    });

    test('a run\'s exclude is added to the target\'s', () {
      expect(of(target, {'DART_TEST_EXCLUDE_TAGS': 'integration'}).arguments, [
        '--tags=unit || integration',
        '--exclude-tags=slow',
        '--exclude-tags=integration',
      ]);
    });

    test('an empty run value means none', () {
      final selection = of(const {}, {
        'DART_TEST_TAGS': '',
        'DART_TEST_EXCLUDE_TAGS': '',
      });
      expect(selection.perRun, isFalse);
      expect(selection.fixed, isFalse);
      expect(selection.arguments, isEmpty);
    });

    test('describes the run\'s selection as it was set', () {
      expect(
        of(target, {
          'DART_TEST_TAGS': 'absent',
          'DART_TEST_EXCLUDE_TAGS': 'x',
        }).describePerRun(),
        'DART_TEST_TAGS=absent and DART_TEST_EXCLUDE_TAGS=x',
      );
      expect(
        of(target, {'DART_TEST_TAGS': 'a'}).describePerRun(),
        'DART_TEST_TAGS=a',
      );
    });

    test('describes the target\'s selection as its attributes say it', () {
      expect(
        of(target).describeFixed(),
        'include_tags = ["unit || integration"] and exclude_tags = ["slow"]',
      );
      expect(
        of({
          'include_tags': ['absent'],
        }).describeFixed(),
        'include_tags = ["absent"]',
      );
    });
  });

  group('orderingSeed', () {
    test('is the run\'s DART_TEST_ORDERING_SEED, as set', () {
      expect(launcher.orderingSeed({'DART_TEST_ORDERING_SEED': '7'}), '7');
      expect(
        launcher.orderingSeed({'DART_TEST_ORDERING_SEED': 'random'}),
        'random',
      );
    });

    test('is none when unset or empty', () {
      expect(launcher.orderingSeed(const {}), isNull);
      expect(launcher.orderingSeed({'DART_TEST_ORDERING_SEED': ''}), isNull);
    });
  });

  group('usedTags', () {
    test('reads the tags the runner names as used but not declared', () {
      expect(
        launcher.usedTags(
          'Warning: A tag was used that wasn\'t specified in dart_test.yaml.\n'
          '  integration was used in the suite itself\n'
          '  unit was used in the test "unit case"\n',
        ),
        {'integration', 'unit'},
      );
    });

    test('is empty for output that names none', () {
      expect(launcher.usedTags('All tests passed!'), isEmpty);
    });
  });

  group('childEnvironment', () {
    test('drops RULES_DART_ variables and keeps the rest', () {
      final env = launcher.childEnvironment({
        'RULES_DART_SOMETHING': 'parent',
        'TEST_TMPDIR': '/t',
        'PATH': '/bin',
      }, const {});
      expect(env, {'TEST_TMPDIR': '/t', 'PATH': '/bin'});
    });

    test('adds the runfiles variables the launcher found', () {
      final env = launcher.childEnvironment(
        {'RUNFILES_DIR': '/old', 'A': 'b'},
        {'RUNFILES_DIR': '/new', 'RUNFILES_MANIFEST_FILE': '/m'},
      );
      expect(env, {
        'A': 'b',
        'RUNFILES_DIR': '/new',
        'RUNFILES_MANIFEST_FILE': '/m',
      });
    });
  });

  group('runfilesPaths', () {
    test('puts the main repository below the workspace', () {
      expect(launcher.runfilesPaths(['a/b.dart', 'c.txt'], workspace: 'ws'), {
        'ws/a/b.dart',
        'ws/c.txt',
      });
    });

    test('takes another repository\'s `../` as its own root', () {
      expect(launcher.runfilesPaths(['../dep+/x/y.dart'], workspace: 'ws'), {
        'dep+/x/y.dart',
      });
    });

    test('skips empty lines', () {
      expect(launcher.runfilesPaths(['', 'a', ''], workspace: 'ws'), {'ws/a'});
    });
  });

  group('RunfilesLayout', () {
    test(
      'reads what is laid out and the SDK from the files the config names',
      () {
        final tmp = Directory.systemTemp.createTempSync('test_runner_layout.');
        addTearDown(() => tmp.deleteSync(recursive: true));
        File('${tmp.path}/laid_out')
            .writeAsStringSync('a.txt\n../dep+/b.txt\n');
        File('${tmp.path}/sdk_files').writeAsStringSync('sdk.txt\n');
        final layout = launcher.RunfilesLayout.read(
          Runfiles.fromState(directory: tmp.path),
          {'workspace': 'ws', 'laid_out': 'laid_out', 'sdk_files': 'sdk_files'},
        );
        expect(layout.laidOut, {'ws/a.txt', 'dep+/b.txt'});
        expect(layout.sdk, {'ws/sdk.txt'});
      },
    );
  });

  group('RunfilesLayout.holds', () {
    test('holds what is laid out, but not the SDK', () {
      final layout = launcher.RunfilesLayout(
        {'ws/a', 'ws/sdk.txt'},
        sdk: {'ws/sdk.txt'},
      );
      expect(layout.holds('ws/a'), isTrue);
      expect(layout.holds('ws/sdk.txt'), isFalse);
      expect(layout.holds('ws/other'), isFalse);
    });
  });

  group('testWorkingDirectory', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('test_runner_unit.'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String path(String relative) =>
        [tmp.path, ...relative.split('/')].join(Platform.pathSeparator);

    File write(String relative, [String content = 'x']) {
      final file = File(path(relative));
      file.parent.createSync(recursive: true);
      return file..writeAsStringSync(content);
    }

    /// The working directory of the test at `ws/pkg/t.dart` in [runfiles],
    /// laying out [laidOut] (but not [sdk]) into `scratch` if it comes to that.
    String run(
      Runfiles runfiles, {
      Set<String> laidOut = const {},
      Set<String> sdk = const {},
      launcher.RunfilesLayout Function()? layout,
    }) => launcher.testWorkingDirectory(
      runfiles: runfiles,
      directory: 'ws/pkg',
      testPath: 't.dart',
      layout: layout ?? () => launcher.RunfilesLayout(laidOut, sdk: sdk),
      scratch: () => Directory(path('scratch'))..createSync(),
    );

    Runfiles manifestOf(List<String> lines) => Runfiles.fromState(
      manifestPath: write('MANIFEST', '${lines.join('\n')}\n').path,
    );

    List<String> laidOutFiles() => [
      for (final e in Directory(path('scratch')).listSync(recursive: true))
        if (e is File)
          e.path.substring(path('scratch').length + 1).replaceAll(r'\', '/'),
    ]..sort();

    test('is the tree\'s directory where the tree holds the test', () {
      write('tree/ws/pkg/t.dart');
      expect(
        run(
          Runfiles.fromState(directory: path('tree')),
          layout: () => fail('a tree needs nothing laid out'),
        ),
        path('tree/ws/pkg'),
      );
    });

    test('lays out from the manifest where there is no tree', () {
      final source = write('src/t.dart', 'test');
      final into = run(
        manifestOf(['ws/pkg/t.dart ${source.path}']),
        laidOut: {'ws/pkg/t.dart'},
      );
      expect(into, path('scratch/ws/pkg'));
      expect(laidOutFiles(), ['ws/pkg/t.dart']);
    });

    test('lays out from the manifest where the tree lacks the test', () {
      write('tree/ws/other.dart');
      final source = write('src/t.dart');
      final runfiles = Runfiles.fromState(
        directory: path('tree'),
        manifestPath: write('MANIFEST', 'ws/pkg/t.dart ${source.path}\n').path,
      );
      expect(run(runfiles, laidOut: {'ws/pkg/t.dart'}), path('scratch/ws/pkg'));
    });

    // Not the launcher's own files, its program and kernels, nor the rest of
    // what the manifest lists for another test that runs this one as its data.
    test('lays out only the runfiles the test brings', () {
      final t = write('src/t.dart');
      final other = write('src/other.dart');
      run(
        manifestOf([
          'ws/pkg/t.dart ${t.path}',
          'ws/pkg/data.txt ${other.path}',
          'ws/launcher.kernel ${other.path}',
        ]),
        laidOut: {'ws/pkg/t.dart', 'ws/pkg/data.txt'},
      );
      expect(laidOutFiles(), ['ws/pkg/data.txt', 'ws/pkg/t.dart']);
    });

    // A repository's files can be symlinks, as a git package's are; each is
    // laid out as what it points at, alone or inside a directory.
    test(
      'lays out a symlink as what it points at, alone or in a directory',
      () {
        write('src/t.dart');
        write('src/real.txt');
        Link(path('src/link.txt')).createSync('real.txt');
        write('src/tree/real.txt');
        Link(path('src/tree/link.txt')).createSync('real.txt');
        run(
          manifestOf([
            'ws/pkg/t.dart ${path('src/t.dart')}',
            'ws/pkg/linked.txt ${path('src/link.txt')}',
            'ws/pkg/tree ${path('src/tree')}',
          ]),
          laidOut: {'ws/pkg/t.dart', 'ws/pkg/linked.txt', 'ws/pkg/tree'},
        );
        expect(laidOutFiles(), [
          'ws/pkg/linked.txt',
          'ws/pkg/t.dart',
          'ws/pkg/tree/link.txt',
          'ws/pkg/tree/real.txt',
        ]);
        for (final laid in laidOutFiles().where((f) => f != 'ws/pkg/t.dart')) {
          final file = File(path('scratch/$laid'));
          expect(file.readAsStringSync(), 'x', reason: laid);
          expect(
            FileSystemEntity.isLinkSync(file.path),
            isFalse,
            reason: '$laid is a copy of what the link points at',
          );
        }
      },
    );

    // The Dart SDK, which `@rules_dart//dart` in `data` brings whole, is
    // found through the manifest and never laid out, though the test brings it.
    test('does not lay out the SDK, though the test brings it', () {
      write('src/t.dart');
      write('src/sdk.txt');
      run(
        manifestOf([
          'ws/pkg/t.dart ${path('src/t.dart')}',
          'ws/pkg/plain.txt ${path('src/sdk.txt')}',
          'ws/pkg/sdk.txt ${path('src/sdk.txt')}',
        ]),
        laidOut: {'ws/pkg/t.dart', 'ws/pkg/plain.txt', 'ws/pkg/sdk.txt'},
        sdk: {'ws/pkg/sdk.txt'},
      );
      expect(laidOutFiles(), ['ws/pkg/plain.txt', 'ws/pkg/t.dart']);
    });

    test('fails with no tree holding the test and no manifest', () {
      expect(
        () => run(Runfiles.fromState(directory: path('tree'))),
        throwsA(
          isA<launcher.TestWorkingDirectoryException>().having(
            (e) => e.message,
            'message',
            allOf(contains('ws/pkg/t.dart'), contains('no runfiles manifest')),
          ),
        ),
      );
    });

    test('fails when the manifest does not list the test', () {
      final manifest = write('MANIFEST', 'ws/other ${path('MANIFEST')}\n');
      expect(
        () => run(
          Runfiles.fromState(manifestPath: manifest.path),
          laidOut: {'ws/pkg/t.dart'},
        ),
        throwsA(
          isA<launcher.TestWorkingDirectoryException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(manifest.path),
              contains('does not list ws/pkg/t.dart'),
            ),
          ),
        ),
      );
    });

    test('fails when what to lay out cannot be read', () {
      final manifest = write('MANIFEST', '');
      expect(
        () => run(
          Runfiles.fromState(manifestPath: manifest.path),
          layout: () => throw const FileSystemException('gone', 'laid_out'),
        ),
        throwsA(
          isA<launcher.TestWorkingDirectoryException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('cannot read what to lay out'),
              contains(manifest.path),
            ),
          ),
        ),
      );
    });
  });

  group('junitXml', () {
    String event(Map<String, Object?> e) => jsonEncode(e);

    List<String> events() => [
      event({
        'type': 'testStart',
        'test': {'id': 1, 'name': 'loading t.dart'},
        'time': 0,
      }),
      event({
        'type': 'testDone',
        'testID': 1,
        'hidden': true,
        'result': 'success',
        'time': 5,
      }),
      event({
        'type': 'testStart',
        'test': {'id': 2, 'name': 'passes <&>'},
        'time': 10,
      }),
      event({'type': 'print', 'testID': 2, 'message': 'hello'}),
      event({
        'type': 'testDone',
        'testID': 2,
        'result': 'success',
        'time': 1510,
      }),
      event({
        'type': 'testStart',
        'test': {'id': 3, 'name': 'fails "q"'},
        'time': 2000,
      }),
      event({
        'type': 'error',
        'testID': 3,
        'error': 'Expected: 1\n  Actual: 2',
        'stackTrace': 'at x',
      }),
      event({
        'type': 'testDone',
        'testID': 3,
        'result': 'failure',
        'time': 2500,
      }),
      event({
        'type': 'testStart',
        'test': {'id': 4, 'name': 'skipped'},
        'time': 3000,
      }),
      event({
        'type': 'testDone',
        'testID': 4,
        'skipped': true,
        'result': 'success',
        'time': 3000,
      }),
      event({
        'type': 'testStart',
        'test': {'id': 5, 'name': 'loading broken.dart'},
        'time': 3000,
      }),
      event({'type': 'error', 'testID': 5, 'error': 'boom', 'stackTrace': 's'}),
      event({
        'type': 'testDone',
        'testID': 5,
        'hidden': true,
        'result': 'error',
        'time': 3100,
      }),
    ];

    test('is one testcase per case, hiding passing loading pseudo-tests', () {
      final xml = launcher.junitXml([
        'not json',
        '',
        '[1]',
        ...events(),
      ], suiteName: 'suite');
      expect(
        [
          for (final m in RegExp(r'<testcase name="([^"]*)"').allMatches(xml))
            m[1],
        ],
        [
          'passes &lt;&amp;&gt;',
          'fails &quot;q&quot;',
          'skipped',
          'loading broken.dart',
        ],
      );
      expect(
        xml,
        contains(
          '<testsuite name="suite" tests="4" failures="1" errors="1" '
          'skipped="1" time="2.100">',
        ),
      );
    });

    test('reports each case\'s time, output, failure and skip', () {
      final xml = launcher.junitXml(events(), suiteName: 'suite');
      expect(xml, contains('classname="suite" time="1.500">'));
      expect(xml, contains('<system-out>hello\n</system-out>'));
      expect(xml, contains('<failure message="Expected: 1">'));
      expect(xml, contains('Actual: 2\nat x</failure>'));
      expect(xml, contains('<skipped/>'));
      expect(xml, contains('<error message="boom">'));
    });

    test('is an empty suite for no events', () {
      expect(
        launcher.junitXml(const [], suiteName: 's'),
        contains(
          '<testsuite name="s" tests="0" failures="0" errors="0" '
          'skipped="0" time="0.000">',
        ),
      );
    });
  });
}
