// The summary analyzer on projects laid out as `dart_info()` and the
// `dart_analyze` aspect stage them: what it reports, where it refuses, and
// which edits leave a summary's bytes unchanged.
//
// Arguments: the runfiles paths of the summary analyzer and of the SDK's
// summary.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

late String tool;
late String sdkSummary;
late Directory scratch;

/// A staged project: `src/<package>/...` files, one package config naming
/// [packages] (each rooted at `src/<name>`), and an options file.
Directory project(
  String name,
  Map<String, String> files, {
  List<String> packages = const [],
  String options = '',
}) {
  final dir = Directory(p.join(scratch.path, name))..createSync();
  for (final MapEntry(:key, :value) in files.entries) {
    File(p.join(dir.path, 'src', key))
      ..createSync(recursive: true)
      ..writeAsStringSync(value);
  }
  for (final package in packages) {
    File(p.join(dir.path, 'src', package, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: $package\nenvironment:\n  sdk: ^3.13.0\n');
  }
  File(p.join(dir.path, '.dart_tool', 'package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '{"configVersion": 2, "packages": [${[for (final package in packages) '{"name": "$package", "rootUri": "../src/$package", '
            '"packageUri": "lib/", "languageVersion": "3.13"}'].join(', ')}]}',
    );
  File(p.join(dir.path, 'analysis_options.yaml')).writeAsStringSync(options);
  return dir;
}

Future<ProcessResult> runTool(List<String> args) {
  // Through a params file, as Bazel passes them.
  final params = File(p.join(scratch.path, 'params-${args.hashCode}'))
    ..writeAsStringSync(args.map((a) => '$a\n').join());
  return Process.run(tool, ['@${params.path}']);
}

/// Summarizes every file under [dir]'s `src/`; returns the summary.
Future<String> summarize(
  Directory dir, {
  List<String> summaries = const [],
}) async {
  final out = '${dir.path}.sum';
  final result = await runTool([
    'summarize',
    '--project',
    dir.path,
    '--options',
    p.join(dir.path, 'analysis_options.yaml'),
    '--sdk-summary',
    sdkSummary,
    for (final s in summaries) ...['--summary', s],
    '--file',
    p.join(dir.path, 'src'),
    '--out',
    out,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  return out;
}

/// Analyzes [dir] against [summaries].
Future<({int exitCode, String output, bool stamped})> analyze(
  Directory dir,
  List<String> summaries,
) async {
  final stamp = '${dir.path}.stamp';
  final result = await runTool([
    'analyze',
    '--project',
    dir.path,
    '--sdk-summary',
    sdkSummary,
    for (final s in summaries) ...['--summary', s],
    '--stamp',
    stamp,
    '--fatal-infos',
  ]);
  return (
    exitCode: result.exitCode,
    output: '${result.stdout}${result.stderr}',
    stamped: File(stamp).existsSync(),
  );
}

const flag = '--@rules_dart//dart:analysis_summaries=false';

const depLibrary = '''
base class Base {}

final class Fin {}

sealed class Shape {}

class Holder {
  int? value;
  int body() {
    return 1;
  }
}

/// Documented.
class Thing {}
''';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  tool = runfiles.rlocation(args[0]);
  sdkSummary = runfiles.rlocation(args[1]);

  setUp(() => scratch = Directory.systemTemp.createTempSync('summaries'));
  tearDown(() => scratch.deleteSync(recursive: true));

  Future<String> dep() => summarize(
    project('dep', {'dep/lib/dep.dart': depLibrary}, packages: ['dep']),
  );

  test('analyzes clean code against a summary and stamps it', () async {
    final summary = await dep();
    final app = project(
      'app',
      {
        'app/lib/app.dart': '''
import 'package:dep/dep.dart';

base class Ok extends Base {}

final class AlsoOk extends Base {}

int use(Holder h) => h.body() + (h.value ?? 0);
''',
      },
      packages: ['app'],
    );
    final result = await analyze(app, [summary]);
    expect(result.exitCode, 0, reason: result.output);
    expect(result.stamped, isTrue);
    expect(result.output, isEmpty);
  });

  test('reports diagnostics by workspace path', () async {
    final summary = await dep();
    final app = project(
      'app',
      {
        'app/lib/app.dart': '''
import 'package:dep/dep.dart';

int use(Holder h) => h.missing;
''',
      },
      packages: ['app'],
    );
    final result = await analyze(app, [summary]);
    expect(result.exitCode, 3);
    expect(result.stamped, isFalse);
    expect(
      result.output,
      contains(
        "error - ${p.join('app', 'lib', 'app.dart')}:3:24 - "
        "The getter 'missing' isn't "
        "defined for the type 'Holder'.",
      ),
    );
  });

  test('refuses a subtype of a dependency\'s base class the analyzer lets '
      'through', () async {
    final summary = await dep();
    final app = project(
      'app',
      {
        'app/lib/app.dart': '''
import 'package:dep/dep.dart';

class Sub extends Base {}
''',
      },
      packages: ['app'],
    );
    final result = await analyze(app, [summary]);
    expect(result.exitCode, isNot(0));
    expect(result.stamped, isFalse);
    expect(
      result.output,
      allOf(
        contains('${p.join('app', 'lib', 'app.dart')}:3:7'),
        contains(
          "The type 'Sub' must be 'base', 'final' or 'sealed' because the "
          "supertype 'Base' is 'base'. - "
          'subtype_of_base_or_final_is_not_base_final_or_sealed',
        ),
        contains(flag),
      ),
    );
  });

  test('refuses where the analyzer crashes', () async {
    final summary = await dep();
    final app = project(
      'app',
      {
        'app/lib/app.dart': '''
import 'package:dep/dep.dart';

int use(Holder h) {
  if (h.value != null) return h.value + 1;
  return 0;
}
''',
      },
      packages: ['app'],
    );
    final result = await analyze(app, [summary]);
    expect(result.exitCode, isNot(0));
    expect(result.output, allOf(contains('crashed'), contains(flag)));
  });

  test('says which comment_references are false', () async {
    final summary = await dep();
    final app = project(
      'app',
      {
        'app/lib/app.dart': '''
/// @docImport 'package:dep/dep.dart';
/// @docImport 'dart:async';
library;

/// See [Thing], [Completer] and [Nowhere].
class A {}
''',
      },
      packages: ['app'],
      options: 'linter:\n  rules:\n    - comment_references\n',
    );
    final result = await analyze(app, [summary]);
    expect(result.exitCode, isNot(0));
    expect(result.output, contains("'Thing' comes from the doc import of"));
    expect(result.output, contains("'Completer' comes from the doc import of"));
    expect(result.output, isNot(contains("'Nowhere' comes from")));
  });

  test('refuses a package split across targets under '
      'prefer_relative_imports', () async {
    final impl = await summarize(
      project(
        'impl',
        {'sp/lib/impl.dart': 'int one() => 1;\n'},
        packages: ['sp'],
      ),
    );
    const options = 'linter:\n  rules:\n    - prefer_relative_imports\n';
    final user = project(
      'user',
      {
        'sp/lib/user.dart': '''
import 'package:sp/impl.dart';

int two() => one() + 1;
''',
      },
      packages: ['sp'],
      options: options,
    );
    final result = await analyze(user, [impl]);
    expect(result.exitCode, isNot(0));
    expect(
      result.output,
      allOf(
        contains('prefer_relative_imports'),
        contains('${p.join('sp', 'lib', 'user.dart')}:1:1'),
      ),
    );
  });

  test('refuses analyzer plugins', () async {
    final app = project(
      'app',
      {'app/lib/app.dart': 'int a = 1;\n'},
      packages: ['app'],
      options: 'analyzer:\n  plugins:\n    - some_plugin\n',
    );
    final result = await analyze(app, []);
    expect(result.exitCode, isNot(0));
    expect(result.output, allOf(contains('some_plugin'), contains(flag)));
  });

  test('summarizes a library with its parts', () async {
    final summary = await summarize(
      project(
        'dep',
        {
          'dep/lib/dep.dart': "part 'src/part.dart';\n\nint a() => b();\n",
          'dep/lib/src/part.dart': "part of '../dep.dart';\n\nint b() => 2;\n",
        },
        packages: ['dep'],
      ),
    );
    final app = project(
      'app',
      {
        'app/lib/app.dart':
            "import 'package:dep/dep.dart';\n\nint c = a() + b();\n",
      },
      packages: ['app'],
    );
    final result = await analyze(app, [summary]);
    expect(result.exitCode, 0, reason: result.output);
  });

  // A generator that writes a part for every source writes one for a
  // library that includes none (json_serializable's `.g.dart` for a file with
  // nothing to generate). No library holds it, so no summary does, and no
  // dependent can reach it.
  test('summarizes a package beside a part no library includes', () async {
    final summary = await summarize(
      project(
        'orphan_dep',
        {
          'dep/lib/dep.dart': "part 'dep.g.dart';\n\nint a() => b();\n",
          'dep/lib/dep.g.dart': "part of 'dep.dart';\n\nint b() => 2;\n",
          'dep/lib/plain.dart': 'int c() => 3;\n',
          'dep/lib/plain.g.dart': "part of 'plain.dart';\n",
        },
        packages: ['dep'],
      ),
    );
    final app = project(
      'orphan_app',
      {
        'app/lib/app.dart':
            "import 'package:dep/dep.dart';\nimport 'package:dep/plain.dart';\n\n"
            'int d = a() + b() + c();\n',
      },
      packages: ['app'],
    );
    final result = await analyze(app, [summary]);
    expect(result.exitCode, 0, reason: result.output);
  });

  group('a summary', () {
    Future<List<int>> bytesOf(String library) async {
      final dir = project(
        'dep${library.hashCode}',
        {'dep/lib/dep.dart': library},
        packages: ['dep'],
      );
      return File(await summarize(dir)).readAsBytesSync();
    }

    test(
      'is the same after an edit inside a body that moves what follows',
      () async {
        final edited = depLibrary.replaceFirst(
          '    return 1;',
          '    var x = 1;\n    x += 2;\n    // More lines.\n    return x - 2;',
        );
        expect(await bytesOf(edited), await bytesOf(depLibrary));
      },
    );

    test('is the same after a comment edit', () async {
      final edited = depLibrary.replaceFirst(
        '/// Documented.',
        '/// Documented,\n///\n/// at length.',
      );
      expect(await bytesOf(edited), await bytesOf(depLibrary));
    });

    test('changes when a private member is added', () async {
      final edited = depLibrary.replaceFirst(
        '  int? value;',
        '  int? value;\n  int _hidden = 3;',
      );
      expect(await bytesOf(edited), isNot(await bytesOf(depLibrary)));
    });
  });
}
