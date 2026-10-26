import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'kernel_tool/args.dart';
import 'kernel_tool/check_command.dart';
import 'kernel_tool/commands.dart';
import 'kernel_tool/compile.dart';
import 'kernel_tool/directives.dart';
import 'kernel_tool/entry_command.dart';
import 'kernel_tool/manifest.dart';
import 'kernel_tool/module_command.dart';
import 'kernel_tool/module_graph.dart';
import 'kernel_tool/policy.dart';
import 'kernel_tool/sources.dart';
import 'kernel_tool/uris.dart';
import 'kernel_tool/worker_command.dart';

const _roots = ['.', 'bazel-out/k8-fastbuild/bin'];

final _packageConfig = jsonEncode({
  'configVersion': 2,
  'packages': [
    {
      'name': 'app',
      'rootUri': 'org-dartlang-root:///app/',
      'packageUri': 'lib/',
    },
    {'name': 'rel', 'rootUri': '../rel', 'packageUri': 'lib/'},
  ],
});

final _librariesJson = jsonEncode({
  'vm_common': {
    'libraries': {'core': {}, 'io': {}, 'ffi': {}},
  },
  'vm': {
    'include': [
      {'target': 'vm_common'},
    ],
    'libraries': {'cli': {}},
  },
});

final _config = PackageConfig.parse(_packageConfig, 'app/pc.json');
final _vm = supportedLibraries(_librariesJson, 'vm');

/// The libraries `files` (exec path to source) make up.
Sources _sources(Map<String, String> files, {Set<String>? supported}) =>
    readLibraries(
      sources: [for (final e in files.entries) SourceFile(e.key, e.value)],
      roots: _roots,
      config: _config,
      supported: supported ?? _vm,
    );

List<PlannedModule> _plan(Map<String, String> files, {Set<String>? supported}) {
  final s = _sources(files, supported: supported);
  return planModules(libraries: s.libraries, supported: supported ?? _vm);
}

/// The libraries of each planned module, short.
List<List<String>> _shapes(List<PlannedModule> modules) => [
  for (final m in modules)
    [for (final l in m.libraries) l.replaceFirst('package:app/', '')],
];

ModuleRecord _module(
  int id,
  List<String> libraries, {
  List<String> deps = const [],
  List<String> parts = const [],
  String status = statusOk,
  String? reason,
}) => ModuleRecord(
  id: id,
  libraries: libraries,
  parts: parts,
  deps: deps,
  dill: status == statusOk ? '$id.dill' : null,
  status: status,
  reason: reason,
);

Manifest _manifest(
  String label,
  List<ModuleRecord> modules, {
  String? package,
  String? libRoot,
}) => Manifest(
  label: label,
  package: package,
  libRoot: libRoot,
  dir: 'out/${label.replaceAll(RegExp('[/:]'), '_')}',
  modules: modules,
);

void main() {
  group('readDirectives', () {
    test('reads directives, parts and whether it is a part', () {
      final d = readDirectives('a.dart', '''
#!/usr/bin/env dart
// comment
@Deprecated('x (')
library a.b;
import 'dart:io' as io show File, Directory hide Link;
import "package:a/a.dart" deferred as a;
export 'src/x.dart' show X;
part 'a.g.dart';
class C {}
''');
      expect(d.directives.map((d) => d.uri), [
        'dart:io',
        'package:a/a.dart',
        'src/x.dart',
      ]);
      expect(d.directives.map((d) => d.isExport), [false, false, true]);
      expect(d.parts, ['a.g.dart']);
      expect(d.isPart, isFalse);
    });

    test('reads configurations and adjacent strings', () {
      final d = readDirectives('a.dart', '''
import 'a.dart'
    if (dart.library.io) 'a_io.dart'
    if (dart.library.html == "true") 'a_html.dart'
    if (my.flag == 'x' 'y') 'a_flag.dart';
import 'dir/' 'b.dart';
import r'c\\d.dart';
''');
      final first = d.directives.first;
      expect(first.uri, 'a.dart');
      expect(first.configurations.map((c) => (c.name, c.value, c.uri)), [
        ('dart.library.io', null, 'a_io.dart'),
        ('dart.library.html', 'true', 'a_html.dart'),
        ('my.flag', 'xy', 'a_flag.dart'),
      ]);
      expect(d.directives[1].uri, 'dir/b.dart');
      expect(d.directives[2].uri, r'c\d.dart');
    });

    test('recognises part files, by name or by URI', () {
      expect(readDirectives('p.dart', "part of 'a.dart';").isPart, isTrue);
      expect(readDirectives('p.dart', 'part of a.b;').isPart, isTrue);
      expect(
        readDirectives('p.dart', '// x\npart of "../a.dart";').isPart,
        isTrue,
      );
    });

    test('ignores native extensions', () {
      final d = readDirectives(
        'a.dart',
        "import 'dart-ext:x'; import 'b.dart';",
      );
      expect(d.directives.map((d) => d.uri), ['b.dart']);
    });

    test('keeps what parsed when the file has syntax errors', () {
      final d = readDirectives('a.dart', "import 'a.dart';\nclass {{{ \n");
      expect(d.directives.map((d) => d.uri), ['a.dart']);
    });

    test('an empty file has no directives', () {
      final d = readDirectives('a.dart', '');
      expect(d.directives, isEmpty);
      expect(d.isPart, isFalse);
    });
  });

  group('supportedLibraries', () {
    test('follows include chains', () {
      expect(supportedLibraries(_librariesJson, 'vm'), {
        'core',
        'io',
        'ffi',
        'cli',
      });
    });
  });

  group('URI mapping', () {
    test('uses the longest matching root', () {
      expect(
        rootRelative('bazel-out/k8-fastbuild/bin/app/lib/a.dart', _roots),
        'app/lib/a.dart',
      );
      expect(rootRelative('app/lib/a.dart', _roots), 'app/lib/a.dart');
      expect(rootRelative('./app/lib/a.dart', _roots), 'app/lib/a.dart');
    });

    test('maps lib files to package URIs and the rest to the root', () {
      expect(_config.uriFor('app/lib/src/a.dart'), 'package:app/src/a.dart');
      expect(
        _config.uriFor('app/test/a_test.dart'),
        rootUri('app/test/a_test.dart'),
      );
    });

    test('resolves a relative rootUri against the config', () {
      expect(_config.uriFor('rel/lib/r.dart'), 'package:rel/r.dart');
      expect(_config.names, {'app', 'rel'});
    });

    test('names the package of a root file', () {
      expect(_config.packageOf('org-dartlang-root:///app/test/a.dart'), 'app');
    });

    test('spells a root file under lib/ as a package URI', () {
      expect(
        _config.canonical('org-dartlang-root:///app/lib/a.dart'),
        'package:app/a.dart',
      );
      expect(
        _config.canonical('org-dartlang-root:///app/test/a.dart'),
        'org-dartlang-root:///app/test/a.dart',
      );
    });

    test('resolves relative imports against package and root URIs', () {
      expect(
        resolveUri('package:app/src/a.dart', '../b.dart'),
        'package:app/b.dart',
      );
      expect(
        resolveUri('org-dartlang-root:///app/bin/m.dart', 'x/y.dart'),
        'org-dartlang-root:///app/bin/x/y.dart',
      );
      expect(resolveUri('package:app/a.dart', 'dart:io'), 'dart:io');
    });
  });

  group('conditional imports', () {
    final supported = {'io', 'core'};
    ResolvedImport pick(String source, [Set<String>? libs]) => resolveImport(
      readDirectives('a.dart', source).directives.single,
      'package:app/a.dart',
      libs ?? supported,
    );

    test('selects the first configuration that holds', () {
      final r = pick('''
import 'a.dart'
    if (dart.library.html) 'web.dart'
    if (dart.library.io) 'io.dart'
    if (dart.library.core) 'core.dart';
''');
      expect(r.selected, 'package:app/io.dart');
      expect(r.reached, ['package:app/io.dart']);
    });

    test('falls back to the default', () {
      expect(
        pick("import 'a.dart' if (dart.library.html) 'web.dart';").selected,
        'package:app/a.dart',
      );
    });

    test('compares with the written value', () {
      expect(
        pick("import 'a.dart' if (dart.library.html == 'false') 'no.dart';")
            .selected,
        'package:app/no.dart',
      );
    });

    test(
      'is undecided when another name is tested, and reaches every branch',
      () {
        final r = pick('''
import 'a.dart'
    if (dart.library.html) 'web.dart'
    if (dart.vm.product) 'prod.dart'
    if (dart.library.io) 'io.dart';
''');
        expect(r.selected, isNull);
        expect(r.defaultUri, 'package:app/a.dart');
        expect(r.reached, [
          'package:app/a.dart',
          'package:app/web.dart',
          'package:app/prod.dart',
          'package:app/io.dart',
        ]);
      },
    );
  });

  group('stronglyConnected', () {
    test('lists each component after those it depends on', () {
      final graph = {
        'a': ['b'],
        'b': ['c', 'd'],
        'c': ['b'],
        'd': <String>[],
      };
      final out = stronglyConnected<String>([
        'a',
        'b',
        'c',
        'd',
      ], (n) => graph[n]!);
      expect(out.map((c) => c.toSet()), [
        {'d'},
        {'b', 'c'},
        {'a'},
      ]);
    });
  });

  group('planModules', () {
    test('a library is a module of its own, with its parts', () {
      final plan = _plan({
        'app/lib/a.dart': "import 'dart:io';\npart 'a.g.dart';",
        'bazel-out/k8-fastbuild/bin/app/lib/a.g.dart': "part of 'a.dart';",
      });
      expect(plan, hasLength(1));
      expect(plan.single.libraries, ['package:app/a.dart']);
      expect(plan.single.parts, ['package:app/a.g.dart']);
      expect(plan.single.unsupported, isEmpty);
    });

    test('part ownership follows the part directive, not the file name', () {
      final plan = _plan({
        'app/lib/a.dart': "part 'x/b.dart';",
        'app/lib/x/b.dart': "part of '../a.dart';",
        'app/lib/orphan.dart': "part of 'nobody.dart';",
      });
      expect(plan.single.parts, ['package:app/x/b.dart']);
    });

    test('libraries that import each other share a module', () {
      final plan = _plan({
        'app/lib/a.dart': "import 'b.dart';",
        'app/lib/b.dart': "import 'c.dart';",
        'app/lib/c.dart': "import 'b.dart';",
      });
      expect(_shapes(plan), [
        ['b.dart', 'c.dart'],
        ['a.dart'],
      ]);
      expect(plan[1].deps, ['package:app/b.dart']);
    });

    test('exports are edges too', () {
      final plan = _plan({
        'app/lib/a.dart': "export 'b.dart';",
        'app/lib/b.dart': "import 'a.dart';",
      });
      expect(_shapes(plan), [
        ['a.dart', 'b.dart'],
      ]);
    });

    test('every library is its own module unless it is in a cycle', () {
      final plan = _plan({
        'app/lib/a.dart': "import 'src/x.dart'; import 'src/y.dart';",
        'app/lib/b.dart': "import 'src/x.dart';",
        'app/lib/src/x.dart': "import 'z.dart';",
        'app/lib/src/y.dart': '',
        'app/lib/src/z.dart': '',
      });
      expect(_shapes(plan), [
        ['src/z.dart'],
        ['src/x.dart'],
        ['src/y.dart'],
        ['a.dart'],
        ['b.dart'],
      ]);
      expect(plan[1].deps, ['package:app/src/z.dart']);
    });

    // A private library only a web entrypoint imports is still a module of its
    // own, so a VM test can import it without reaching the web entrypoint.
    test(
      'leaves a leaf apart from the unsupported library that imports it',
      () {
        final plan = _plan({
          'app/lib/app_web.dart': "export 'src/runtime_web.dart';",
          'app/lib/src/runtime_web.dart': '''
import 'dart:js_interop';
import 'pool_workers.dart';
import 'trap_explain.dart';
''',
          'app/lib/src/pool_workers.dart': '',
          'app/lib/src/trap_explain.dart': '',
        });
        expect(_shapes(plan), [
          ['src/pool_workers.dart'],
          ['src/trap_explain.dart'],
          ['src/runtime_web.dart'],
          ['app_web.dart'],
        ]);
        expect(plan.where((m) => m.unsupported.isNotEmpty).single.libraries, [
          'package:app/src/runtime_web.dart',
        ]);
        expect(plan[0].unsupported, isEmpty);
      },
    );

    test('files outside lib/ are modules too, depending on lib/', () {
      final plan = _plan({
        'app/lib/a.dart': '',
        'app/test/a_test.dart': "import '../lib/a.dart';",
        'app/test/helper.dart': '',
        'app/bin/m.dart': "import 'package:app/a.dart';",
      });
      expect([
        for (final m in plan) m.libraries.single.split('/').last,
      ], unorderedEquals(['a.dart', 'a_test.dart', 'helper.dart', 'm.dart']));
      expect(plan.first.libraries, ['package:app/a.dart']);
      final test = plan.firstWhere(
        (m) => m.libraries.single.endsWith('a_test.dart'),
      );
      // The relative import of a lib file is the module's dependency on it.
      expect(test.deps, ['package:app/a.dart']);
    });

    test('directories that import each other in a cycle share a module', () {
      final plan = _plan({
        'app/test/a.dart': "import '../tool/b.dart';",
        'app/tool/b.dart': "import '../test/a.dart';",
      });
      expect(plan, hasLength(1));
      expect(plan.single.libraries, hasLength(2));
    });

    test('follows the branch of a conditional import the platform takes', () {
      final plan = _plan({
        'app/lib/a.dart': '''
import 'stub.dart' if (dart.library.io) 'src/io.dart' if (dart.library.html) 'src/web.dart';
''',
        'app/lib/stub.dart': '',
        'app/lib/src/io.dart': '',
        'app/lib/src/web.dart': "import 'dart:html';",
      });
      // a depends on io.dart; web.dart is no one's dependency, and it alone is
      // unsupported.
      final a = plan.firstWhere(
        (m) => m.libraries.contains('package:app/a.dart'),
      );
      expect(a.deps, ['package:app/src/io.dart']);
      expect(plan.where((m) => m.unsupported.isNotEmpty).single.libraries, [
        'package:app/src/web.dart',
      ]);
    });

    test('an undecidable condition depends on every branch', () {
      final plan = _plan({
        'app/lib/a.dart': "import 'a1.dart' if (dart.vm.product) 'a2.dart' if (dart.library.io) 'a3.dart';",
        'app/lib/a1.dart': '',
        'app/lib/a2.dart': '',
        'app/lib/a3.dart': '',
      });
      expect(
        plan.firstWhere((m) => m.libraries.contains('package:app/a.dart')).deps,
        ['package:app/a1.dart', 'package:app/a2.dart', 'package:app/a3.dart'],
      );
    });

    test(
      'a module importing a dart: library the platform lacks is unsupported',
      () {
        final plan = _plan({
          'app/lib/a.dart': "import 'dart:io';",
          'app/lib/b.dart': "import 'dart:html'; import 'dart:mirrors';",
          'app/lib/c.dart': "import 'b.dart';",
        });
        final byLib = {for (final m in plan) m.libraries.single: m};
        expect(byLib['package:app/a.dart']!.unsupported, isEmpty);
        expect(byLib['package:app/b.dart']!.unsupported, [
          'package:app/b.dart imports dart:html',
          'package:app/b.dart imports dart:mirrors',
        ]);
        expect(byLib['package:app/c.dart']!.unsupported, isEmpty);
      },
    );

    test(
      'a dart: import in an unselected branch does not make it unsupported',
      () {
        final plan = _plan({
          'app/lib/a.dart': "import 'x.dart' if (dart.library.html) 'y.dart';",
          'app/lib/x.dart': '',
          'app/lib/y.dart': '',
        });
        expect(plan.expand((m) => m.unsupported), isEmpty);
      },
    );

    test('orders modules dependencies first, the same every time', () {
      final files = {
        'app/lib/z.dart': '',
        'app/lib/m.dart': "import 'z.dart';",
        'app/lib/a.dart': "import 'm.dart';",
      };
      final first = _shapes(_plan(files));
      expect(first, [
        ['z.dart'],
        ['m.dart'],
        ['a.dart'],
      ]);
      expect(
        _shapes(_plan(Map.fromEntries(files.entries.toList().reversed))),
        first,
      );
    });

    test('a package imported from outside the target is a dependency, not a module', () {
      final plan = _plan({'app/lib/a.dart': "import 'package:other/o.dart';"});
      expect(plan.single.deps, ['package:other/o.dart']);
    });
  });

  group('checkPolicy', () {
    List<Violation> check(
      Map<String, String> files, {
      Set<String> available = const {},
      bool layering = false,
      Set<String> direct = const {},
      Set<String> depFiles = const {},
      String? own,
    }) {
      final libraries = <String, ImportingFile>{};
      final parts = <String>{};
      for (final e in files.entries) {
        final uri = _config.uriFor(rootRelative(e.key, _roots));
        final d = readDirectives(e.key, e.value);
        if (d.isPart) {
          parts.add(uri);
          continue;
        }
        libraries[uri] = ImportingFile(e.key, [
          for (final directive in d.directives)
            ...resolveImport(directive, uri, null, _config).candidates,
        ]);
      }
      return checkPolicy(
        label: '//app:lib',
        libraries: libraries,
        partFiles: parts,
        config: _config,
        availablePackages: available,
        dependencyFiles: depFiles,
        checkLayering: layering,
        directPackages: direct,
        ownPackage: own,
      );
    }

    test('reports every import of a package no dependency provides', () {
      final v = check({
        'app/lib/a.dart': '''
import 'package:missing/m.dart';
import 'package:missing/n.dart';
import 'package:missing/m.dart';
import 'package:app/a.dart';
import 'package:rel/ok.dart';
''',
      });
      expect(v.map((v) => v.message), [
        '//app:lib: app/lib/a.dart imports package:missing/m.dart, but no '
            'dependency of //app:lib provides package "missing". Add the target '
            'that provides it to deps.',
        '//app:lib: app/lib/a.dart imports package:missing/n.dart, but no '
            'dependency of //app:lib provides package "missing". Add the target '
            'that provides it to deps.',
      ]);
      expect(v.map((v) => v.library), [
        'package:app/a.dart',
        'package:app/a.dart',
      ]);
    });

    test('accepts packages from the available list', () {
      expect(
        check(
          {'app/lib/a.dart': "import 'package:dep/d.dart';"},
          available: {'dep'},
        ),
        isEmpty,
      );
    });

    test('looks at every library, not only those a program reaches', () {
      final v = check({
        'app/lib/a.dart': '',
        'app/lib/src/unused.dart': "import 'package:missing/m.dart';",
      });
      expect(v.single.library, 'package:app/src/unused.dart');
    });

    test('looks at every branch of a conditional import', () {
      final v = check(
        {
          'app/lib/a.dart': '''
import 'package:one/a.dart'
    if (dart.library.io) 'package:two/a.dart'
    if (dart.library.html) 'package:three/a.dart';
''',
        },
        available: {'one'},
      );
      expect(v.map((v) => v.message), [
        contains('package:two/a.dart'),
        contains('package:three/a.dart'),
      ]);
    });

    test('a part file is not checked as a library', () {
      expect(
        check({
          'app/lib/a.dart': "part 'a.g.dart';",
          'app/lib/a.g.dart': "part of 'a.dart';",
        }, own: 'app'),
        isEmpty,
      );
    });

    test('a file of the own package that nothing compiles is reported', () {
      final v = check(
        {
          'app/lib/a.dart':
              "import 'package:app/missing.dart'; import 'b.dart';",
        },
        own: 'app',
        depFiles: {'package:app/b.dart'},
      );
      expect(v.map((v) => v.message), [
        '//app:lib: app/lib/a.dart imports package:app/missing.dart, a file of its '
            'own package that neither //app:lib nor any of its deps compiles. Add '
            'the target that holds it to deps.',
      ]);
    });

    test('a file a dependency holds is not missing', () {
      expect(
        check(
          {'app/lib/a.dart': "import 'package:app/b.dart';"},
          own: 'app',
          depFiles: {'package:app/b.dart'},
        ),
        isEmpty,
      );
    });

    test('layering: only direct dependencies and the own package', () {
      final files = {
        'app/lib/a.dart': '''
import 'package:direct/d.dart';
import 'package:indirect/i.dart';
import 'package:app/own.dart';
''',
      };
      expect(
        check(
          files,
          available: {'direct', 'indirect'},
          own: 'app',
          depFiles: {'package:app/own.dart'},
        ),
        isEmpty,
      );
      final v = check(
        files,
        available: {'direct', 'indirect', 'app'},
        layering: true,
        direct: {'direct'},
        own: 'app',
        depFiles: {'package:app/own.dart'},
      );
      expect(v.map((v) => v.message), [
        '//app:lib: app/lib/a.dart imports package:indirect/i.dart, but package '
            '"indirect" is not a direct dependency of //app:lib, only of '
            'something it depends on. Add the target that provides it to deps.',
      ]);
    });
  });

  group('checkPolicy with a config naming every reachable package', () {
    // What `check` is given: the target's own package and every transitive
    // one, so that dependency files map to URIs. A package being in it must
    // not exempt an import from the layering check.
    final everything = PackageConfig.parse('''
{"configVersion": 2, "packages": [
  {"name": "app", "rootUri": "org-dartlang-root:///app/", "packageUri": "lib/"},
  {"name": "direct", "rootUri": "org-dartlang-root:///direct/", "packageUri": "lib/"},
  {"name": "indirect", "rootUri": "org-dartlang-root:///indirect/", "packageUri": "lib/"}
]}''', 'app/pc.json');

    test('layering still reports a package only a dependency provides', () {
      final uri = everything.uriFor(rootRelative('app/lib/a.dart', _roots));
      final d = readDirectives(
        'app/lib/a.dart',
        "import 'package:direct/d.dart';\nimport 'package:indirect/i.dart';",
      );
      final v = checkPolicy(
        label: '//app:lib',
        libraries: {
          uri: ImportingFile('app/lib/a.dart', [
            for (final directive in d.directives)
              ...resolveImport(directive, uri, null, everything).candidates,
          ]),
        },
        partFiles: const {},
        config: everything,
        availablePackages: const {'app', 'direct', 'indirect'},
        dependencyFiles: const {},
        checkLayering: true,
        directPackages: const {'direct'},
        ownPackage: 'app',
      );
      expect(v.map((v) => v.message), [
        '//app:lib: app/lib/a.dart imports package:indirect/i.dart, but package '
            '"indirect" is not a direct dependency of //app:lib, only of '
            'something it depends on. Add the target that provides it to deps.',
      ]);
    });
  });

  group('module verdicts', () {
    PlannedModule plan({
      List<String> deps = const [],
      List<String> unsupported = const [],
      List<String> libraries = const ['package:t/t.dart'],
    }) => PlannedModule(
      libraries: libraries,
      parts: const [],
      deps: deps,
      unsupported: unsupported,
    );

    ({String status, String reason})? verdict(
      PlannedModule p,
      List<Manifest> deps,
    ) => moduleVerdict(p, 'vm', ModuleIndex(deps).reach(p.deps));

    test('a module of usable dependencies can be compiled', () {
      final dep = _manifest('//d:d', [
        _module(0, ['package:d/d.dart']),
      ]);
      expect(verdict(plan(deps: ['package:d/d.dart']), [dep]), isNull);
    });

    test('importing a dart: library the platform lacks is unsupported', () {
      final v = verdict(
        plan(unsupported: ['package:t/t.dart imports dart:html']),
        [],
      )!;
      expect(v.status, statusUnsupported);
      expect(
        v.reason,
        'is unsupported: package:t/t.dart imports dart:html, which the vm '
        'target does not provide',
      );
    });

    test('depending on an unsupported module fails, naming the cause', () {
      final dep = _manifest('//d:d', [
        _module(
          0,
          ['package:d/d.dart'],
          status: statusUnsupported,
          reason:
              'is unsupported: package:d/d.dart imports dart:html, which '
              'the vm target does not provide',
        ),
      ]);
      final v = verdict(plan(deps: ['package:d/d.dart']), [dep])!;
      expect(v.status, statusFailed);
      expect(
        v.reason,
        'depends on package:d/d.dart (//d:d), which is unsupported: '
        'package:d/d.dart imports dart:html, which the vm target does not '
        'provide',
      );
    });

    test('failure propagates across targets, with the root cause and its diagnostics', () {
      final c = _manifest('//c:c', [
        _module(
          0,
          ['package:c/c.dart'],
          status: statusFailed,
          reason: 'does not compile\nc.dart:1:1: Error: nope',
        ),
      ]);
      final b = _manifest('//b:b', [
        _module(
          1,
          ['package:b/b.dart'],
          deps: ['package:c/c.dart'],
          status: statusFailed,
          reason: moduleVerdict(
            plan(deps: ['package:c/c.dart']),
            'vm',
            ModuleIndex([c]).reach(['package:c/c.dart']),
          )!.reason,
        ),
      ]);
      final expected =
          'depends on package:c/c.dart (//c:c), which does not compile\n'
          'c.dart:1:1: Error: nope';
      final v = verdict(plan(deps: ['package:b/b.dart']), [c, b])!;
      expect(v.status, statusFailed);
      expect(v.reason, expected);
      // The same through a module that only knows its dependency by reason.
      expect(verdict(plan(deps: ['package:b/b.dart']), [b])!.reason, expected);
    });

    test('a dependency nothing provides is not a reason to fail', () {
      // It can only be a branch of a conditional import not taken.
      expect(verdict(plan(deps: ['package:nobody/n.dart']), []), isNull);
    });
  });

  group('ModuleIndex', () {
    test('finds the module of a library and walks dependencies first', () {
      final a = _manifest('//a:a', [
        _module(0, ['package:a/a.dart'], deps: ['package:b/b.dart']),
        _module(1, ['package:a/other.dart']),
      ]);
      final b = _manifest('//b:b', [
        _module(0, ['package:b/b.dart'], deps: ['package:c/c.dart']),
      ]);
      final c = _manifest('//c:c', [
        _module(0, ['package:c/c.dart'], parts: ['package:c/c.g.dart']),
      ]);
      final index = ModuleIndex([c, b, a]);
      expect(index.moduleOf('package:a/a.dart')!.manifest, a);
      expect(index.moduleOf('package:c/c.g.dart'), isNull);
      final reach = index.reach(['package:a/a.dart']);
      expect(reach.order.map((m) => m.manifest.label), [
        '//c:c',
        '//b:b',
        '//a:a',
      ]);
      expect(reach.via[reach.order.last], 'package:a/a.dart');
      // Only what is reached: not a:other.
      expect(reach.order, hasLength(3));
    });

    test('a package from a second hub is ignored whole', () {
      final first = _manifest(
        '//hub1:p',
        [
          _module(0, ['package:p/p.dart']),
        ],
        package: 'p',
        libRoot: '../hub1',
      );
      final second = _manifest(
        '//hub2:p',
        [
          _module(0, ['package:p/p.dart']),
          _module(1, ['package:p/extra.dart']),
        ],
        package: 'p',
        libRoot: '../hub2',
      );
      final index = ModuleIndex([first, second]);
      expect(index.moduleOf('package:p/p.dart')!.manifest, first);
      expect(index.moduleOf('package:p/extra.dart'), isNull);
    });

    test('any other overlap leaves the library to the earlier module', () {
      final first = _manifest('//a:a', [
        _module(0, ['package:x/x.dart']),
      ]);
      final second = _manifest('//b:b', [
        _module(0, ['package:x/x.dart', 'package:y/y.dart']),
      ]);
      final index = ModuleIndex([first, second]);
      expect(index.moduleOf('package:x/x.dart')!.manifest, first);
      expect(index.moduleOf('package:y/y.dart')!.manifest, second);
    });
  });

  group('reachError', () {
    ModuleReach reach(List<Manifest> manifests, List<String> imports) =>
        ModuleIndex(manifests).reach(imports);

    test('is null when everything reached is ok', () {
      final a = _manifest('//a:a', [
        _module(0, ['package:a/a.dart']),
      ]);
      expect(
        reachError('//t:t', 'main.dart', reach([a], ['package:a/a.dart'])),
        isNull,
      );
    });

    test('names the first bad module met, with its diagnostics', () {
      final a = _manifest('//a:a', [
        _module(0, ['package:a/ok.dart']),
        _module(
          1,
          ['package:a/bad.dart'],
          status: statusFailed,
          reason: 'does not compile\nbad.dart:3:1: Error: no',
        ),
      ]);
      expect(
        reachError(
          '//t:t',
          'main.dart',
          reach([a], ['package:a/ok.dart', 'package:a/bad.dart']),
        ),
        '//t:t: main.dart reaches package:a/bad.dart (//a:a), which does not '
        'compile\nbad.dart:3:1: Error: no',
      );
    });
  });

  group('uniqueModules', () {
    ModuleRef ref(Manifest m, int i) => ModuleRef(m, m.modules[i]);

    test('keeps modules that share nothing', () {
      final a = _manifest('//a:a', [
        _module(0, ['package:x/1.dart']),
      ]);
      final b = _manifest('//b:b', [
        _module(0, ['package:x/2.dart']),
      ]);
      final u = uniqueModules([ref(a, 0), ref(b, 0)]);
      expect(u.kept, hasLength(2));
      expect(u.conflicts, isEmpty);
    });

    test('drops the later copy of a package from a second hub', () {
      final a = _manifest(
        '//h1:p',
        [
          _module(0, ['package:p/p.dart']),
        ],
        package: 'p',
        libRoot: '../h1',
      );
      final b = _manifest(
        '//h2:p',
        [
          _module(0, ['package:p/p.dart']),
        ],
        package: 'p',
        libRoot: '../h2',
      );
      final u = uniqueModules([ref(a, 0), ref(b, 0)]);
      expect(u.kept.map((r) => r.manifest.label), ['//h1:p']);
      expect(u.conflicts, isEmpty);
    });

    test('reports any other overlap', () {
      final a = _manifest('//a:a', [
        _module(0, ['package:x/1.dart']),
      ]);
      final b = _manifest('//b:b', [
        _module(0, ['package:x/1.dart']),
      ]);
      final u = uniqueModules([ref(a, 0), ref(b, 0)]);
      expect(u.kept.map((r) => r.manifest.label), ['//a:a']);
      expect(overlapMessages('//t:t', u.conflicts), [
        '//t:t: package:x/1.dart is compiled into both //a:a and //b:b. A '
            'library can belong to only one target; remove it from one of them.',
      ]);
    });

    test('same package and same lib_root is still an error', () {
      final a = _manifest(
        '//a:p',
        [
          _module(0, ['package:p/p.dart']),
        ],
        package: 'p',
        libRoot: 'r',
      );
      final b = _manifest(
        '//b:p',
        [
          _module(0, ['package:p/p.dart']),
        ],
        package: 'p',
        libRoot: 'r',
      );
      expect(uniqueModules([ref(a, 0), ref(b, 0)]).conflicts, hasLength(1));
    });

    test('lists every duplicate', () {
      final a = _manifest('//a:a', [
        _module(0, ['package:x/1.dart', 'package:x/2.dart']),
      ]);
      final b = _manifest('//b:b', [
        _module(0, ['package:x/1.dart', 'package:x/2.dart']),
      ]);
      expect(
        uniqueModules([ref(a, 0), ref(b, 0)]).conflicts.map((o) => o.uri),
        ['package:x/1.dart', 'package:x/2.dart'],
      );
    });
  });

  group('Args', () {
    test('keeps a value that starts with @, such as a label', () {
      final args = Args.parse('module', ['--label', '@@repo//:lib']);
      expect(args.one('label'), '@@repo//:lib');
    });

    test('expands a params file only when asked', () {
      final dir = Directory.systemTemp.createTempSync('kernel_tool_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final params = File('${dir.path}/p')
        ..writeAsStringSync('--label\n@@x//:y\n');
      expect(Args.expand(['@${params.path}']), ['--label', '@@x//:y']);
      expect(Args.expand(['--label', 'a']), ['--label', 'a']);
    });

    test('reports a missing or unknown option instead of exiting', () {
      expect(
        () => Args.parse('module', []).one('label'),
        throwsA(isA<UsageException>()),
      );
      expect(
        () => Args.parse('module', ['--nope', 'x']),
        throwsA(isA<UsageException>()),
      );
      expect(
        () => Args.parse('module', ['--check-layering']),
        throwsA(isA<UsageException>()),
      );
    });

    test('a bad command line is a failed run', () async {
      expect(await runKernelTool(['module', '--nope', 'x']), 64);
    });
  });

  group('serve', () {
    test('closes and succeeds when the loop ends', () async {
      var closed = false;
      final code = await serve(
        () async {},
        () async => closed = true,
        const Stream.empty(),
      );
      expect(code, 0);
      expect(closed, isTrue);
    });

    test('a stop kills a compiler that would never exit', () async {
      if (Platform.isWindows) return;
      // A "compiler" that ignores its stdin, as a kernel_worker does whose
      // stdin a stray forked child holds open.
      final dir = Directory.systemTemp.createTempSync('serve_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      // It names itself, so the test needs no `ps`, which a minimal Linux
      // image lacks; `exec` keeps the pid.
      final pidFile = File('${dir.path}/compiler.pid');
      final script = File('${dir.path}/compiler.sh')
        ..writeAsStringSync('echo \$\$ > ${pidFile.path}\nexec sleep 600\n');
      final kernel = KernelWorker('/bin/sh', script.path);
      final stop = StreamController<void>();
      final served = serve(
        () {
          kernel.compile([], [], Digests()).ignore();
          return Completer<void>().future;
        },
        kernel.close,
        stop.stream,
      );
      final compiler = await _pid(pidFile);
      stop.add(null);
      expect(await served, 143);
      expect(await _gone(compiler), isTrue);
    });
  });

  group('Digests', () {
    test('prefers the digest Bazel gave, else hashes the file once', () {
      final dir = Directory.systemTemp.createTempSync('kernel_tool_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/f')..writeAsStringSync('abc');
      expect(
        Digests({
          file.path: [1, 2, 3],
        }).of(file.path),
        [1, 2, 3],
      );
      final hashed = Digests().of(file.path);
      expect(hashed, hasLength(32));
      file.writeAsStringSync('changed');
      expect(Digests().of(file.path), isNot(hashed));
    });
  });

  group('FrontendServerOutput', () {
    test('separates the protocol from the diagnostics', () {
      final out = FrontendServerOutput.parse(
        'result abc\nfile.dart:1:1: Error: bad\nabc\n+file:///x.dart\nabc out.dill 1\n',
      );
      expect(out.errorCount, 1);
      expect(out.diagnostics, 'file.dart:1:1: Error: bad\n');
    });

    test('reports no count when there is no result line', () {
      expect(FrontendServerOutput.parse('crash').errorCount, isNull);
    });
  });

  test('Manifest round-trips through JSON', () {
    final dir = Directory.systemTemp.createTempSync('kernel_tool_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final m = _manifest(
      '//a:a',
      [
        _module(
          0,
          ['package:a/a.dart'],
          parts: ['package:a/a.g.dart'],
          deps: ['package:b/b.dart'],
        ),
        _module(
          1,
          ['package:a/x.dart'],
          status: statusFailed,
          reason: 'does not compile\nboom',
        ),
      ],
      package: 'a',
      libRoot: 'lib',
    );
    final file = File('${dir.path}/m.json')..writeAsStringSync(m.toJson());
    final back = Manifest.read('out', file.path);
    expect(back.label, '//a:a');
    expect(back.package, 'a');
    expect(back.libRoot, 'lib');
    expect(back.modules[0].dill, '0.dill');
    expect(back.modules[0].parts, ['package:a/a.g.dart']);
    expect(back.modules[0].deps, ['package:b/b.dart']);
    expect(back.modules[1].dill, isNull);
    expect(back.modules[1].status, statusFailed);
    expect(back.modules[1].reason, 'does not compile\nboom');
  });

  group('commands', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('kernel_tool_test_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String path(String name) => '${dir.path}/$name';

    File write(String name, String content) {
      final file = File(path(name));
      file.parent.createSync(recursive: true);
      return file..writeAsStringSync(content);
    }

    /// Args for a `module` that never reaches the compiler: every module is
    /// unsupported or failed before it would be compiled.
    List<String> moduleArgs(
      String name,
      Map<String, String> sources, {
      List<(String name, Manifest manifest)> deps = const [],
      List<String> extra = const [],
      String lib = 'lib',
    }) {
      write('libraries.json', _librariesJson);
      final srcs = <String>[];
      for (final e in sources.entries) {
        srcs.addAll(['--src', write('root/${e.key}', e.value).path]);
      }
      final depArgs = <String>[];
      for (final (d, m) in deps) {
        write('$d.json', m.toJson());
        depArgs.addAll([
          '--dep-modules',
          path(d),
          '--dep-manifest',
          path('$d.json'),
        ]);
      }
      return [
        'module',
        '--label',
        '//app:$name',
        '--platform',
        'unused.dill',
        '--libraries-spec',
        path('libraries.json'),
        '--libraries-target',
        'vm',
        '--package-config',
        path('root/app/pc.json'),
        '--package-name',
        'app',
        '--lib-root',
        'app',
        '--multi-root',
        path('root'),
        ...srcs,
        ...depArgs,
        '--output-dir',
        path('$name.modules'),
        '--manifest-output',
        path('$name.modules.json'),
        ...extra,
      ];
    }

    Future<int> runArgs(List<String> args) async {
      final params = write('params_${args.hashCode}', args.skip(1).join('\n'));
      return runKernelTool([args.first, '@${params.path}']);
    }

    Map<String, dynamic> manifestOf(String name) =>
        jsonDecode(File(path('$name.modules.json')).readAsStringSync())
            as Map<String, dynamic>;

    test('module records an unsupported module and fails its dependents without compiling', () async {
      write('root/app/pc.json', _packageConfig);
      final args = moduleArgs('lib', {
        'app/lib/ok_web.dart': "import 'dart:html';",
        'app/lib/uses_web.dart': "import 'ok_web.dart';",
      });
      expect(await runArgs(args), 0);
      final m = manifestOf('lib');
      expect(m['label'], '//app:lib');
      expect(m['package'], 'app');
      final modules = (m['modules'] as List).cast<Map<String, dynamic>>();
      expect(modules.map((m) => m['status']), ['unsupported', 'failed']);
      expect(modules.map((m) => m['dill']), [null, null]);
      expect(modules[0]['reason'], contains('imports dart:html'));
      expect(
        modules[1]['reason'],
        startsWith('depends on package:app/ok_web.dart (//app:lib)'),
      );
      expect(modules[1]['deps'], ['package:app/ok_web.dart']);
      expect(Directory(path('lib.modules')).existsSync(), isTrue);
    });

    test(
      'module fails a dependent of a failed module in another target',
      () async {
        write('root/app/pc.json', _packageConfig);
        final dep = _manifest('//dep:dep', [
          _module(
            0,
            ['package:dep/d.dart'],
            status: statusFailed,
            reason: 'does not compile\nd.dart:1:1: Error: no',
          ),
        ]);
        final args = moduleArgs(
          'lib',
          {'app/lib/a.dart': "import 'package:dep/d.dart';"},
          deps: [('dep.modules', dep)],
        );
        expect(await runArgs(args), 0);
        final modules = (manifestOf('lib')['modules'] as List)
            .cast<Map<String, dynamic>>();
        expect(modules.single['status'], 'failed');
        expect(
          modules.single['reason'],
          'depends on package:dep/d.dart (//dep:dep), which does not compile\n'
          'd.dart:1:1: Error: no',
        );
      },
    );

    List<String> checkArgs(
      Map<String, String> sources, {
      List<String> depFiles = const [],
      List<String> extra = const [],
    }) {
      write('root/app/pc.json', _packageConfig);
      return [
        'check',
        '--label',
        '//app:lib',
        '--package-config',
        path('root/app/pc.json'),
        '--package-name',
        'app',
        '--lib-root',
        'app',
        '--multi-root',
        path('root'),
        for (final e in sources.entries) ...[
          '--src',
          write('root/${e.key}', e.value).path,
        ],
        for (final f in depFiles) ...['--dep-file', f],
        '--output',
        path('lib.check'),
        ...extra,
      ];
    }

    test('check writes the stamp when every import is declared', () async {
      final args = checkArgs(
        {
          'app/lib/a.dart': '''
import 'package:dep/d.dart';
import 'b.dart' if (dart.library.html) 'package:dep/web.dart';
''',
          'app/lib/b.dart': '',
        },
        extra: ['--available-package', 'dep'],
      );
      expect(await runArgs(args), 0);
      expect(File(path('lib.check')).readAsStringSync(), isEmpty);
    });

    test('check reports every violation and writes no stamp', () async {
      final args = checkArgs({
        'app/lib/a.dart': "import 'package:missing/m.dart';",
        'app/lib/b.dart': "import 'package:also_missing/m.dart';",
      });
      final err = StringBuffer();
      final code = await runCheck(Args.parse('check', args.skip(1)), err: err);
      expect(code, 1);
      expect(err.toString(), contains('package "missing"'));
      expect(err.toString(), contains('package "also_missing"'));
      expect(File(path('lib.check')).existsSync(), isFalse);
    });

    test(
      'check sees a branch of a conditional import no platform takes',
      () async {
        final args = checkArgs({
          'app/lib/a.dart': "import 'b.dart' if (dart.library.nothing) 'package:missing/m.dart';",
          'app/lib/b.dart': '',
        });
        expect(await runArgs(args), 1);
      },
    );

    test('check finds a file of the own package in the deps, tree directories included', () async {
      write('dep_files/lib/b.dart', '');
      final args = checkArgs(
        {'app/lib/a.dart': "import 'package:app/b.dart';"},
        depFiles: [path('dep_files')],
      );
      // `dep_files` is not under the multi-root, so the file is not at the URI
      // `package:app/b.dart`: the import is still missing.
      expect(await runArgs(args), 1);

      write('root/app/lib/b.dart', '');
      final inRoot = checkArgs(
        {'app/lib/a.dart': "import 'package:app/b.dart';"},
        depFiles: [path('root/app/lib')],
      );
      expect(await runArgs(inRoot), 0);
    });

    test('check applies layering when asked', () async {
      final args = checkArgs(
        {'app/lib/a.dart': "import 'package:indirect/i.dart';"},
        extra: [
          '--available-package',
          'indirect',
          '--check-layering',
          '--direct-package',
          'direct',
        ],
      );
      expect(await runArgs(args), 1);
    });

    test(
      'module with nothing to compile writes an empty directory and manifest',
      () async {
        write('root/app/pc.json', _packageConfig);
        final args = moduleArgs('lib', {});
        expect(await runArgs(args), 0);
        expect(manifestOf('lib')['modules'], isEmpty);
        expect(Directory(path('lib.modules')).listSync(), isEmpty);
      },
    );

    List<String> entryArgs(String main, List<(String, Manifest)> deps) {
      write('root/app/pc.json', _packageConfig);
      final depArgs = <String>[];
      for (final (d, m) in deps) {
        write('$d.json', m.toJson());
        depArgs.addAll([
          '--dep-modules',
          path(d),
          '--dep-manifest',
          path('$d.json'),
        ]);
      }
      return [
        'entry',
        '--label',
        '//app:t',
        '--runtime',
        'unused',
        '--platform',
        'unused.dill',
        '--sdk-root',
        'unused',
        '--package-config',
        path('root/app/pc.json'),
        '--multi-root',
        path('root'),
        ...depArgs,
        '--main',
        write('root/app/main.dart', main).path,
        '--output',
        path('t.dill'),
        '--selection-output',
        path('t.selection.json'),
      ];
    }

    test('entry fails when main reaches an unsupported module', () async {
      final dep = _manifest('//dep:dep', [
        _module(
          0,
          ['package:dep/d.dart'],
          status: statusUnsupported,
          reason: 'is unsupported: package:dep/d.dart imports dart:html',
        ),
      ]);
      final code = await runArgs(
        entryArgs("import 'package:dep/d.dart';", [('dep.modules', dep)]),
      );
      expect(code, 1);
      expect(File(path('t.dill')).existsSync(), isFalse);
      expect(File(path('t.selection.json')).existsSync(), isFalse);
    });

    test(
      'entry fails when main imports a library no dependency compiles',
      () async {
        expect(
          await runArgs(entryArgs("import 'package:nobody/n.dart';", [])),
          1,
        );
      },
    );

    test('link writes the entry first, then the selected modules', () async {
      final a = _manifest('//a:a', [
        _module(0, ['package:a/a.dart']),
        _module(1, ['package:a/b.dart']),
      ]);
      final b = _manifest('//b:b', [
        _module(0, ['package:b/b.dart']),
      ]);
      write('a.modules.json', a.toJson());
      write('b.modules.json', b.toJson());
      write('entry.dill', 'ENTRY');
      write('a.modules/0.dill', 'A0');
      write('b.modules/0.dill', 'B0');
      write(
        'selection.json',
        jsonEncode({
          'modules': [
            {'label': '//b:b', 'id': 0},
            {'label': '//a:a', 'id': 0},
          ],
        }),
      );
      final code = await runArgs([
        'link',
        '--label',
        '//app:t',
        '--entry',
        path('entry.dill'),
        '--selection',
        path('selection.json'),
        '--dep-manifest',
        path('a.modules.json'),
        '--dep-manifest',
        path('b.modules.json'),
        '--output',
        path('t.program.dill'),
      ]);
      expect(code, 0);
      expect(File(path('t.program.dill')).readAsStringSync(), 'ENTRYB0A0');
    });

    test('link refuses a library two selected modules define', () async {
      final a = _manifest('//a:a', [
        _module(0, ['package:x/x.dart']),
      ]);
      final b = _manifest('//b:b', [
        _module(0, ['package:x/x.dart']),
      ]);
      write('a.modules.json', a.toJson());
      write('b.modules.json', b.toJson());
      write('entry.dill', 'ENTRY');
      write('a.modules/0.dill', 'X');
      write('b.modules/0.dill', 'X');
      write(
        'selection.json',
        jsonEncode({
          'modules': [
            {'label': '//a:a', 'id': 0},
            {'label': '//b:b', 'id': 0},
          ],
        }),
      );
      final code = await runArgs([
        'link',
        '--label',
        '//app:t',
        '--entry',
        path('entry.dill'),
        '--selection',
        path('selection.json'),
        '--dep-manifest',
        path('a.modules.json'),
        '--dep-manifest',
        path('b.modules.json'),
        '--output',
        path('t.program.dill'),
      ]);
      expect(code, 1);
    });
  });
}

/// The pid written to [file], once it is.
Future<int> _pid(File file) async {
  for (var i = 0; i < 100; i++) {
    final pid = file.existsSync()
        ? int.tryParse(file.readAsStringSync().trim())
        : null;
    if (pid != null) return pid;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('nothing wrote a pid to ${file.path}');
}

/// Whether process [child] has exited within a few seconds.
Future<bool> _gone(int child) async {
  for (var i = 0; i < 100; i++) {
    // A signal that leaves a running process be, and fails once it is gone.
    if (!Process.killPid(child, ProcessSignal.sigcont)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}
