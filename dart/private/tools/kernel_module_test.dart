// Tests the planner of `kernel_module.dart`: which sources a module compiles, which it
// excludes and why, and what each compile is given. The compiler is a recorder, so no
// `kernel_worker` runs. The planner decides before it compiles, so nothing else is
// needed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'dill_outline.dart'
    show Tag, stripDillToOutline, supportedKernelFormatVersions;
import 'kernel_link.dart' show KernelLinkCache, linkOne;
import 'kernel_module.dart'
    show
        ModuleCompiler,
        ModuleOutcome,
        compileModule,
        scanDirectives,
        stripSourceCodeFromDill;

const _prefix = 'org-dartlang-bazel:///';

/// The test's files: sources, module directories and sidecars, and the configs.
late Directory _root;

/// A compiler that records each request's arguments and succeeds.
class _Recorder implements ModuleCompiler {
  final List<List<String>> calls = [];

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    calls.add(args);
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

/// The values that follow each `flag` in `args`, in order.
List<String> _valuesAfter(List<String> args, String flag) => [
  for (var i = 0; i + 1 < args.length; i++)
    if (args[i] == flag) args[i + 1],
];

/// A module's directory, which holds its `index.json`.
class _Scc {
  _Scc(this.dill, this.defines, this.imports);

  final String dill;
  final List<String> defines;
  final List<String> imports;
}

/// The outcome of one planned compile.
class _Result {
  _Result(this.code, this.calls, this.sidecar, this.index);

  final int code;
  final List<List<String>> calls;
  final String sidecar;
  final Map<String, dynamic> index;

  /// The excluded sources, by URI, with the reason each is excluded.
  Map<String, String> get excluded => {
    for (final line in const LineSplitter().convert(sidecar))
      if (line.isNotEmpty && !line.startsWith('#'))
        line.split('\t').first: line.split('\t').last,
  };

  /// The `defines` of each kernel the module wrote, in order.
  List<List<String>> get defines => [
    for (final scc in (index['sccs'] as List).cast<Map<String, dynamic>>())
      (scc['defines'] as List).cast<String>(),
  ];

  /// The `--source` URIs of each compile, in order.
  List<List<String>> get sourcesPerCall => [
    for (final call in calls) _valuesAfter(call, '--source'),
  ];
}

String _uri(String key) => '$_prefix$key';

void _write(String relative, String text) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

/// Writes a dependency module directory with `sccs`, and returns its path.
String _module(String name, List<_Scc> sccs) {
  _write(
    '$name/index.json',
    jsonEncode({
      'version': 1,
      'sccs': [
        for (final scc in sccs)
          {'dill': scc.dill, 'defines': scc.defines, 'imports': scc.imports},
      ],
    }),
  );
  return '${_root.path}/$name';
}

/// Writes the `.vm_excluded.txt` sidecar of a module, with `excluded` as its sources.
String _sidecar(String name, Map<String, String> excluded) {
  final lines = [
    for (final entry in excluded.entries) '${_uri(entry.key)}\t${entry.value}',
  ];
  _write('$name.vm_excluded.txt', lines.map((line) => '$line\n').join());
  return '${_root.path}/$name.vm_excluded.txt';
}

/// Plans and compiles one module named `name` from `sources`, which are keys under the
/// test's root (`pkg/lib/a.dart`). Returns what it wrote and what it asked the compiler.
Future<_Result> _compile(
  String name,
  List<String> sources, {
  List<String> inputKmods = const [],
  List<String> closureExcluded = const [],
  bool noDrop = false,
  String? outputOutline,
  String? scheme,
  String? librariesPlatform,
  List<String> extraLibraries = const [],
  String? packagesFile,
}) async {
  final output = '${_root.path}/out/$name';
  final excludedPath = '$output.vm_excluded.txt';
  final prefix = scheme == null ? _prefix : '$scheme:///';
  final args = <String>[
    for (final source in sources) ...['--source', '$prefix$source'],
    '--output',
    output,
    if (outputOutline != null) ...['--output-outline', outputOutline],
    '--excluded-output',
    excludedPath,
    '--packages-file',
    packagesFile ?? '${_root.path}/package_config.json',
    '--libraries-json',
    '${_root.path}/libraries.json',
    if (librariesPlatform != null) ...[
      '--libraries-platform',
      librariesPlatform,
    ],
    for (final lib in extraLibraries) ...['--extra-library', lib],
    '--multi-root',
    _root.path,
    if (scheme != null) ...['--multi-root-scheme', scheme],
    '--target',
    'vm',
    if (noDrop) '--no-drop',
    for (final dir in inputKmods) ...['--input-kmod', dir],
    for (final sidecar in closureExcluded) ...['--closure-excluded', sidecar],
  ];
  final recorder = _Recorder();
  final code = await compileModule(args, recorder, StringBuffer(), const []);
  final written = code == 0
      ? jsonDecode(File('$output/index.json').readAsStringSync())
            as Map<String, dynamic>
      : <String, dynamic>{'sccs': <dynamic>[]};
  return _Result(
    code,
    recorder.calls,
    code == 0 ? File(excludedPath).readAsStringSync() : '',
    written,
  );
}

Uint8List _buildMinimalFieldDill({
  int formatVersion = Tag.BinaryFormatVersion,
  int languageMajor = 3,
}) {
  final out = BytesBuilder();
  void u30(int v) {
    assert(v >= 0 && v < 0x80);
    out.addByte(v);
  }

  void u32(int v) {
    out.addByte((v >> 24) & 0xff);
    out.addByte((v >> 16) & 0xff);
    out.addByte((v >> 8) & 0xff);
    out.addByte(v & 0xff);
  }

  // 18-byte header + problemsAsJson (UInt30(0))
  u32(Tag.ComponentFile);
  u32(formatVersion);
  for (var i = 0; i < 10; i++) {
    out.addByte(0);
  }
  u30(0);

  final libStart = out.length;
  out.addByte(0); // flags
  u30(languageMajor); // major
  u30(0); // minor
  u30(1); // canonicalName
  u30(1); // name
  u30(0); // fileUri
  u30(0); // problemsAsJson
  u30(0); // annotations
  u30(0); // depCount
  u30(0); // expCount
  u30(0); // partCount
  u30(0); // tdCount
  u30(1); // clsCount = 1

  final clsStart = out.length;
  out.addByte(Tag.Class);
  u30(1); // canonicalName
  u30(0); // fileUri
  u30(0);
  u30(0);
  u30(0); // 3 offsets
  u30(0); // flags (not a mixin)
  u30(1); // name
  u30(0); // annotations
  u30(0); // typeParameters
  out.addByte(Tag.Nothing); // supertype
  out.addByte(Tag.Nothing); // mixedInType
  u30(0); // implementedTypes

  // 3 fields: (flags=1 final instance, val=42), (flags=5 static final, val=99), (flags=0 mutable, val=77)
  u30(3);
  for (final (flags, val) in [(1, 42), (5, 99), (0, 77)]) {
    out.addByte(Tag.Field);
    u30(1);
    u30(1);
    u30(0); // 3 canonRefs
    u30(0); // uriRef
    u30(0);
    u30(0); // 2 offsets
    u30(flags);
    u30(1); // name ("f")
    u30(0); // scopeSize
    u30(0); // annotations
    out.addByte(Tag.DynamicType);
    out.addByte(Tag.Nothing); // option variable
    out.addByte(Tag.Something); // option expression
    out.addByte(Tag.PositiveIntLiteral);
    u30(0); // fileOffset
    u30(val);
    out.addByte(Tag.Nothing); // option scope
  }
  u30(0); // ctorCount = 0
  u30(0); // pCount = 0
  final clsProcEnd = out.length;
  u32(clsProcEnd);
  u32(0); // procCount = 0
  final clsEnd = out.length;

  u30(0); // extCount
  u30(0); // extTypeCount
  u30(0); // fieldCount
  u30(2); // pCount = 2
  final procOffsets = <int>[];
  for (final (flags, val) in [(9, 88), (1, 66)]) {
    procOffsets.add(out.length);
    out.addByte(Tag.Procedure);
    u30(1); // canonicalName
    u30(0); // fileUri
    u30(0);
    u30(0);
    u30(0); // 3 offsets
    out.addByte(0); // kind
    out.addByte(0); // stubKind
    u30(flags); // flags (9 = FlagStatic | FlagConst, 1 = FlagStatic)
    u30(1); // name ("f")
    u30(0); // annotations
    u30(0); // stubTarget
    out.addByte(Tag.Nothing); // signatureType
    out.addByte(Tag.FunctionNode);
    u30(0);
    u30(0); // 2 offsets
    out.addByte(0); // asyncMarker
    out.addByte(0); // dartAsyncMarker
    u30(0); // scopeSize
    u30(0); // typeParameters
    out.addByte(Tag.Nothing); // thisVariable
    u30(0); // totalParameterCount
    u30(0); // requiredParameterCount
    u30(0); // posCount
    u30(0); // namedCount
    out.addByte(Tag.DynamicType); // returnType
    out.addByte(Tag.Nothing); // futureValueType
    out.addByte(0); // rftTag
    out.addByte(Tag.Something); // body Option<Statement>
    out.addByte(Tag.ReturnStatement);
    u30(0); // fileOffset
    out.addByte(Tag.Something); // expression
    out.addByte(Tag.PositiveIntLiteral);
    u30(0); // fileOffset
    u30(val);
    out.addByte(Tag.Nothing); // option scope
    out.addByte(Tag.Nothing); // option captured contexts
  }
  final libProcEnd = out.length;
  procOffsets.add(libProcEnd);
  final sourceRefsOffset = out.length;
  u30(0); // usedCount = 0
  u32(sourceRefsOffset);
  u32(clsStart);
  u32(clsEnd);
  u32(1); // classCount = 1
  for (final off in procOffsets) {
    u32(off);
  }
  u32(2); // procCount = 2
  final libEnd = out.length;

  // Source table
  final sourceTableOffset = libEnd;
  u32(1); // uriCount = 1
  final uriEntry0 = out.length;
  u30(0); // uriLen
  u30(0); // srcLen
  u30(0); // lineCount
  u30(0); // impLen
  u30(0); // covCount
  u32(uriEntry0);

  // Constant table
  final constantTableOffset = out.length;
  u30(0); // constCount = 0
  final constantTableIndexOffset = out.length;
  u32(0); // constCount = 0

  // Link table
  final linkTableOffset = out.length;
  u30(1); // canonCount = 1
  u30(0); // parent
  u30(1); // string index 1

  // Metadata
  final metaOffset = out.length;
  u32(0);

  // String table: ["", "f"]
  final stringTableOffset = out.length;
  u30(2);
  u30(0);
  u30(1);
  out.addByte(102); // "f"

  // Component index
  final componentIndexOffset = out.length;
  u32(sourceTableOffset);
  u32(constantTableOffset);
  u32(constantTableIndexOffset);
  u32(linkTableOffset);
  u32(metaOffset);
  u32(metaOffset);
  u32(stringTableOffset);
  u32(componentIndexOffset);
  u32(0); // mainMethodReference
  u32(libStart);
  u32(libEnd);
  u32(1); // libraryCount = 1
  u32(out.length + 4);
  return out.toBytes();
}

bool _containsSubsequence(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('kernel_module_test_');
    _write(
      'package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final name in ['pkg', 'dep'])
            {'name': name, 'rootUri': '$_prefix$name', 'packageUri': 'lib/'},
        ],
      }),
    );
    // A VM with `async`, `core` and `io`, and no `html`.
    _write(
      'libraries.json',
      jsonEncode({
        'vm': {
          'libraries': {'async': {}, 'core': {}, 'io': {}},
        },
      }),
    );
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('a library that imports only the VM compiles every source', () async {
    _write('pkg/lib/a.dart', "import 'dart:async';\nclass A {}\n");
    _write('pkg/lib/b.dart', "import 'a.dart';\nclass B {}\n");
    final result = await _compile('m', ['pkg/lib/a.dart', 'pkg/lib/b.dart']);
    expect(result.code, 0);
    expect(result.excluded, isEmpty);
    expect(result.defines, [
      ['pkg/lib/a.dart'],
      ['pkg/lib/b.dart'],
    ]);
  });

  test(
    'a file that imports a library the VM lacks excludes its importers',
    () async {
      _write('pkg/lib/web.dart', "import 'dart:html';\nclass Web {}\n");
      _write('pkg/lib/uses_web.dart', "import 'web.dart';\n");
      _write('pkg/lib/plain.dart', "import 'dart:io';\nclass Plain {}\n");
      final result = await _compile('m', [
        'pkg/lib/web.dart',
        'pkg/lib/uses_web.dart',
        'pkg/lib/plain.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, {
        _uri('pkg/lib/web.dart'): 'dart:html is not a VM library',
        _uri('pkg/lib/uses_web.dart'):
            'imports ${_uri('pkg/lib/web.dart')}, which is excluded',
      });
      expect(result.defines, [
        ['pkg/lib/plain.dart'],
      ]);
    },
  );

  test('a file that imports a package the module does not have is excluded', () async {
    // `absent` is in no package config, as `json_annotation` is in no closure of
    // `_advanced_sources`.
    _write('pkg/lib/needs.dart', "import 'package:absent/absent.dart';\n");
    _write('pkg/lib/fine.dart', "import 'package:pkg/other.dart';\n");
    _write('pkg/lib/other.dart', 'class Other {}\n');
    final result = await _compile('m', [
      'pkg/lib/needs.dart',
      'pkg/lib/fine.dart',
      'pkg/lib/other.dart',
    ]);
    expect(result.code, 0);
    expect(result.excluded, {
      _uri(
        'pkg/lib/needs.dart',
      ): 'package:absent/absent.dart names a package this module does not have',
    });
    expect(result.defines, [
      ['pkg/lib/other.dart'],
      ['pkg/lib/fine.dart'],
    ]);
  });

  test(
    'a library whose part is not an input is excluded with its importers',
    () async {
      // `role.dart` declares a part that exists only on the wrapping library, as in
      // json_serializable's `_advanced_sources`.
      _write('pkg/lib/role.dart', "part 'role.g.dart';\nenum Role { a }\n");
      _write('pkg/lib/user.dart', "import 'role.dart';\n");
      _write('pkg/lib/extra.dart', 'class Extra {}\n');
      final result = await _compile('m', [
        'pkg/lib/role.dart',
        'pkg/lib/user.dart',
        'pkg/lib/extra.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, {
        _uri('pkg/lib/role.dart'):
            'its part role.g.dart is not an input of this module',
        _uri('pkg/lib/user.dart'):
            'imports ${_uri('pkg/lib/role.dart')}, which is excluded',
      });
      expect(result.defines, [
        ['pkg/lib/extra.dart'],
      ]);
    },
  );

  test(
    'a library and its part compile together when both are inputs',
    () async {
      _write('pkg/lib/role.dart', "part 'role.g.dart';\nenum Role { a }\n");
      _write('pkg/lib/role.g.dart', "part of 'role.dart';\nconst kRole = 1;\n");
      final result = await _compile('m', [
        'pkg/lib/role.dart',
        'pkg/lib/role.g.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, isEmpty);
      expect(result.defines, [
        ['pkg/lib/role.dart', 'pkg/lib/role.g.dart'],
      ]);
    },
  );

  test('a source a dependency module defines is not compiled again', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final dep = _module('dep_module', [
      _Scc('0.dill', ['pkg/lib/shared.dart'], []),
    ]);
    final result = await _compile(
      'm',
      ['pkg/lib/shared.dart', 'pkg/lib/top.dart'],
      inputKmods: [dep],
    );
    expect(result.code, 0);
    expect(result.excluded, isEmpty);
    expect(result.sourcesPerCall, [
      [_uri('pkg/lib/top.dart')],
    ]);
    expect(_valuesAfter(result.calls.single, '--input-summary'), [
      '$dep/0.dill',
    ], reason: 'top links the kernel that defines shared');
  });

  test('a dependency excludes a file the dependent lists, so the dependent compiles its own', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    final dep = _module('dep_module', []);
    final sidecar = _sidecar('dep_module', {
      'pkg/lib/shared.dart': 'imports dart:html, which is not a VM library',
    });
    final result = await _compile(
      'm',
      ['pkg/lib/shared.dart'],
      inputKmods: [dep],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(
      result.excluded,
      isEmpty,
      reason: 'the module compiles its own copy',
    );
    expect(result.defines, [
      ['pkg/lib/shared.dart'],
    ]);
  });

  test('a file a dependency excludes, that a dependent only imports, excludes its importer', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final dep = _module('dep_module', []);
    final sidecar = _sidecar('dep_module', {
      'pkg/lib/shared.dart': 'its reason',
    });
    final result = await _compile(
      'm',
      ['pkg/lib/top.dart'],
      inputKmods: [dep],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(result.excluded, {
      _uri('pkg/lib/top.dart'): 'imports shared.dart, which is excluded',
    });
  });

  test('an excluded file that another module of the closure defines is not excluded', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final excludes = _module('excludes', []);
    final defines = _module('defines', [
      _Scc('0.dill', ['pkg/lib/shared.dart'], []),
    ]);
    final sidecar = _sidecar('excludes', {'pkg/lib/shared.dart': 'its reason'});
    final result = await _compile(
      'm',
      ['pkg/lib/top.dart'],
      inputKmods: [excludes, defines],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(
      result.excluded,
      isEmpty,
      reason: 'the defining module supplies the file',
    );
    expect(result.defines, [
      ['pkg/lib/top.dart'],
    ]);
    expect(_valuesAfter(result.calls.single, '--input-summary'), [
      '$defines/0.dill',
    ]);
  });

  test('an entry compiles an excluded file from source, unless a module defines it', () async {
    _write('pkg/lib/web.dart', 'class Web {}\n');
    _write('pkg/lib/defined.dart', 'class Defined {}\n');
    _write(
      'pkg/test/main_test.dart',
      "import 'package:pkg/web.dart';\nimport 'package:pkg/defined.dart';\n",
    );
    final excludes = _module('excludes', []);
    final defines = _module('defines', [
      _Scc('0.dill', ['pkg/lib/defined.dart'], []),
    ]);
    final sidecar = _sidecar('excludes', {
      'pkg/lib/web.dart': 'dart:html is not a VM library',
      'pkg/lib/defined.dart': 'dart:html is not a VM library',
    });
    final entry = await _compile(
      'entry',
      ['pkg/test/main_test.dart'],
      inputKmods: [excludes, defines],
      closureExcluded: [sidecar],
      noDrop: true,
    );
    expect(entry.code, 0);
    expect(
      entry.sourcesPerCall.single,
      containsAll([_uri('pkg/test/main_test.dart'), 'package:pkg/web.dart']),
    );
    expect(
      entry.sourcesPerCall.single,
      isNot(contains('package:pkg/defined.dart')),
      reason: 'the defining module supplies it',
    );
    expect(
      _valuesAfter(entry.calls.single, '--input-summary'),
      contains('$defines/0.dill'),
    );
  });

  test(
    'the same sources give the same kernels and index in any order',
    () async {
      _write('pkg/lib/b.dart', "import 'a.dart';\n");
      _write('pkg/lib/a.dart', 'class A {}\n');
      final first = await _compile('m1', ['pkg/lib/b.dart', 'pkg/lib/a.dart']);
      final second = await _compile('m2', ['pkg/lib/a.dart', 'pkg/lib/b.dart']);
      expect(first.defines, second.defines);
      expect(first.index, second.index);
    },
  );

  test(
    'a custom --multi-root-scheme resolves package roots, sources and sidecars',
    () async {
      const appPrefix = 'org-dartlang-app:///';
      _write(
        'app_package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final name in ['pkg', 'dep'])
              {
                'name': name,
                'rootUri': '$appPrefix$name',
                'packageUri': 'lib/',
              },
          ],
        }),
      );
      _write('pkg/lib/a.dart', "import 'package:pkg/b.dart';\nclass A {}\n");
      _write('pkg/lib/b.dart', "import 'dart:async';\nclass B {}\n");
      _write('pkg/lib/web.dart', "import 'dart:html';\nclass Web {}\n");
      final result = await _compile(
        'app_m',
        ['pkg/lib/a.dart', 'pkg/lib/b.dart', 'pkg/lib/web.dart'],
        scheme: 'org-dartlang-app',
        packagesFile: '${_root.path}/app_package_config.json',
      );
      expect(result.code, 0);
      expect(result.defines, [
        ['pkg/lib/b.dart'],
        ['pkg/lib/a.dart'],
      ]);
      expect(result.excluded, {
        '${appPrefix}pkg/lib/web.dart': 'dart:html is not a VM library',
      });
      expect(_valuesAfter(result.calls.first, '--multi-root-scheme'), [
        'org-dartlang-app',
      ]);
    },
  );

  test('--extra-library makes dart:ui available for imports and conditional imports', () async {
    _write('pkg/lib/widget.dart', "import 'dart:ui';\nclass W {}\n");
    _write(
      'pkg/lib/entry.dart',
      "import 'stub.dart' if (dart.library.ui) 'real.dart';\n",
    );
    _write('pkg/lib/stub.dart', "import 'dart:html';\n");
    _write('pkg/lib/real.dart', "import 'widget.dart';\n");

    // Without `--extra-library ui`, `widget.dart` is excluded and `entry.dart`
    // takes `stub.dart` (which imports `dart:html` and is also excluded).
    final withoutUi = await _compile('no_ui', [
      'pkg/lib/widget.dart',
      'pkg/lib/entry.dart',
      'pkg/lib/stub.dart',
      'pkg/lib/real.dart',
    ]);
    expect(withoutUi.code, 0);
    expect(withoutUi.defines, isEmpty);

    // With `--extra-library ui`, `widget.dart` compiles and `entry.dart`
    // resolves its conditional import to `real.dart`.
    final withUi = await _compile(
      'with_ui',
      [
        'pkg/lib/widget.dart',
        'pkg/lib/entry.dart',
        'pkg/lib/stub.dart',
        'pkg/lib/real.dart',
      ],
      extraLibraries: ['ui', 'dart:nativewrappers'],
    );
    expect(withUi.code, 0);
    expect(withUi.defines, [
      ['pkg/lib/widget.dart'],
      ['pkg/lib/real.dart'],
      ['pkg/lib/entry.dart'],
    ]);
    expect(withUi.excluded, {
      _uri('pkg/lib/stub.dart'): 'dart:html is not a VM library',
    });
    for (final call in withUi.calls) {
      expect(call, isNot(contains('--extra-library')));
    }
  });

  test(
    '--libraries-platform includes both the named platform and vm libraries',
    () async {
      _write(
        'libraries.json',
        jsonEncode({
          'vm': {
            'libraries': {'async': {}, 'core': {}, 'io': {}},
          },
          'flutter': {
            'libraries': {'ui': {}},
          },
        }),
      );
      _write(
        'pkg/lib/both.dart',
        "import 'dart:io';\nimport 'dart:ui';\nclass Both {}\n",
      );
      final result = await _compile('flutter_m', [
        'pkg/lib/both.dart',
      ], librariesPlatform: 'flutter');
      expect(result.code, 0);
      expect(result.excluded, isEmpty);
      expect(result.defines, [
        ['pkg/lib/both.dart'],
      ]);
      expect(result.calls.single, isNot(contains('--libraries-platform')));
    },
  );

  test('--output-outline creates the outline directory and writes index.json without forwarding the flag', () async {
    _write('pkg/lib/a.dart', "import 'dart:async';\nclass A {}\n");
    final outlineDir = '${_root.path}/out/m.koutline';
    final result = await _compile('m', [
      'pkg/lib/a.dart',
    ], outputOutline: outlineDir);
    expect(result.code, 0);
    expect(result.calls.single, isNot(contains('--output-outline')));
    final outlineIndex = jsonDecode(
      File('$outlineDir/index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(outlineIndex, result.index);
  });

  test('stripDillToOutline preserves final instance field initializers and strips static final and mutable field initializers', () {
    final raw = _buildMinimalFieldDill();
    final stripped = stripDillToOutline(raw);
    expect(
      _containsSubsequence(stripped, [
        Tag.Something,
        Tag.PositiveIntLiteral,
        0,
        42,
      ]),
      isTrue,
      reason: 'non-static final instance field initializer must be preserved for const constructor evaluation',
    );
    expect(
      _containsSubsequence(stripped, [
        Tag.Something,
        Tag.PositiveIntLiteral,
        0,
        99,
      ]),
      isFalse,
      reason: 'static final field initializer should be stripped',
    );
    expect(
      _containsSubsequence(stripped, [
        Tag.Something,
        Tag.PositiveIntLiteral,
        0,
        77,
      ]),
      isFalse,
      reason: 'mutable instance field initializer should be stripped',
    );
    expect(
      _containsSubsequence(stripped, [Tag.PositiveIntLiteral, 0, 88]),
      isTrue,
      reason: 'const procedure body (e.g. extension type const constructor) must be preserved',
    );
    expect(
      _containsSubsequence(stripped, [Tag.PositiveIntLiteral, 0, 66]),
      isFalse,
      reason: 'non-const procedure body should be stripped',
    );
  });

  test('scanDirectives and compileModule handle shebangs and generic annotations in directive prologues', () async {
    final scanned = scanDirectives(
      "#!/usr/bin/env dart\n"
      "@Tag<int>()\n"
      "@prefix.Meta<Map<String, List<int>>>.named('x')\n"
      "library my_lib;\n"
      "@Annot<String>()\n"
      "import 'package:pkg/a.dart';\n"
      "export 'package:pkg/b.dart';\n",
      {'core', 'async'},
    );
    expect(scanned, isNotNull);
    expect(scanned!.refs.map((r) => r.uri).toList(), [
      'package:pkg/a.dart',
      'package:pkg/b.dart',
    ]);

    _write(
      'pkg/lib/shebang_web.dart',
      "#!/usr/bin/env dart\nimport 'dart:html';\nvoid main() {}\n",
    );
    _write(
      'pkg/lib/generic_annot.dart',
      "@Tag<Map<String, List<int>>>.named()\nimport 'plain.dart';\nclass G {}\n",
    );
    _write('pkg/lib/plain.dart', "class Plain {}\n");
    final result = await _compile('prologue_m', [
      'pkg/lib/shebang_web.dart',
      'pkg/lib/generic_annot.dart',
      'pkg/lib/plain.dart',
    ]);
    expect(result.code, 0);
    expect(result.excluded, {
      _uri('pkg/lib/shebang_web.dart'): 'dart:html is not a VM library',
    });
    expect(result.defines, [
      ['pkg/lib/plain.dart'],
      ['pkg/lib/generic_annot.dart'],
    ]);
  });

  test('an entry module resolves relative ../lib/ imports under the multi-root scheme and excludes own keys from index imports', () async {
    _write('dep/lib/ext.dart', 'class Ext {}\n');
    _write(
      'pkg/lib/local_helper.dart',
      "import 'package:dep/ext.dart';\nint helper() => 1;\n",
    );
    _write(
      'pkg/test/my_test.dart',
      "import '../lib/local_helper.dart';\nvoid main() { helper(); }\n",
    );
    final depMod = _module('dep_mod', [
      _Scc('0.dill', ['dep/lib/ext.dart'], []),
    ]);
    final entry = await _compile(
      'rel_entry',
      ['pkg/test/my_test.dart', 'pkg/lib/local_helper.dart'],
      inputKmods: [depMod],
      noDrop: true,
    );
    expect(entry.code, 0);
    expect(
      entry.sourcesPerCall.single,
      containsAll([
        _uri('pkg/test/my_test.dart'),
        _uri('pkg/lib/local_helper.dart'),
      ]),
      reason: 'relative ../lib/ import from test/ resolves under multi-root scheme in CFE',
    );
    final sccImports =
        ((entry.index['sccs'] as List).single
                as Map<String, dynamic>)['imports']
            as List;
    expect(
      sccImports,
      ['dep/lib/ext.dart'],
      reason: 'entry index imports must only list external module keys, not entry own sources',
    );
  });

  test('KernelLinkCache detects in-place mutations with identical size and mtime when digests are absent', () {
    final cache = KernelLinkCache();
    final modDir = Directory('${_root.path}/kmod')..createSync(recursive: true);
    final indexFile = File('${modDir.path}/index.json');
    final dillFile = File('${modDir.path}/0.dill');
    final baseKeysFile = File('${_root.path}/base.keys');
    final outFile = File('${_root.path}/linked.dill');

    final indexV1 = jsonEncode({
      'version': 1,
      'sccs': [
        {
          'dill': '0.dill',
          'defines': ['pkg/lib/a.dart'],
          'imports': <String>[],
        },
      ],
    });
    final indexV2 = jsonEncode({
      'version': 1,
      'sccs': [
        {
          'dill': '0.dill',
          'defines': ['pkg/lib/b.dart'],
          'imports': <String>[],
        },
      ],
    });
    expect(indexV1.length, indexV2.length);

    final fixedTime = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    indexFile.writeAsStringSync(indexV1);
    indexFile.setLastModifiedSync(fixedTime);

    dillFile.writeAsBytesSync([1, 2, 3, 4]);
    dillFile.setLastModifiedSync(fixedTime);

    baseKeysFile.writeAsStringSync('pkg/lib/x.dart\n');
    baseKeysFile.setLastModifiedSync(fixedTime);

    final err1 = StringBuffer();
    expect(
      linkOne(
        [outFile.path, modDir.path],
        cache: cache,
        inputs: null,
        errSink: err1,
      ),
      0,
    );
    expect(outFile.readAsBytesSync(), [1, 2, 3, 4]);
    expect(cache.baseKeysOf(baseKeysFile.path, null), {'pkg/lib/x.dart'});

    // Mutate index.json, 0.dill, and base.keys in-place with identical size and mtime.
    indexFile.writeAsStringSync(indexV2);
    indexFile.setLastModifiedSync(fixedTime);
    expect(indexFile.statSync().size, indexV1.length);
    expect(indexFile.statSync().modified, fixedTime);

    dillFile.writeAsBytesSync([9, 8, 7, 6]);
    dillFile.setLastModifiedSync(fixedTime);
    expect(dillFile.statSync().size, 4);
    expect(dillFile.statSync().modified, fixedTime);

    baseKeysFile.writeAsStringSync('pkg/lib/y.dart\n');
    baseKeysFile.setLastModifiedSync(fixedTime);
    expect(baseKeysFile.statSync().modified, fixedTime);

    final err2 = StringBuffer();
    expect(
      linkOne(
        [outFile.path, modDir.path],
        cache: cache,
        inputs: const {},
        errSink: err2,
      ),
      0,
    );
    expect(
      outFile.readAsBytesSync(),
      [9, 8, 7, 6],
      reason: 'dillBytesOf must not return stale bytes on same-(size, mtime) mutation',
    );
    expect(
      cache.kernelsOf(modDir.path, const {}).single.defines,
      ['pkg/lib/b.dart'],
      reason: 'kernelsOf must not return stale index.json on same-(size, mtime) mutation',
    );
    expect(
      cache.baseKeysOf(baseKeysFile.path, const {}),
      {'pkg/lib/y.dart'},
      reason: 'baseKeysOf must not return stale keys on same-(size, mtime) mutation',
    );
  });

  test('KernelLinkCache normalizes ./ prefixes when matching WorkRequest.inputs digests', () {
    final cache = KernelLinkCache();
    final prevCwd = Directory.current;
    Directory.current = _root;
    try {
      Directory('norm_mod').createSync(recursive: true);
      final dillFile = File('norm_mod/0.dill')..writeAsBytesSync([10, 20, 30]);
      final digest1 = Uint8List.fromList([1, 1, 1, 1]);
      final digest2 = Uint8List.fromList([2, 2, 2, 2]);

      // Populate cache using './norm_mod/0.dill' while inputs key is 'norm_mod/0.dill'.
      final bytes1 = cache.dillBytesOf('./norm_mod/0.dill', {
        'norm_mod/0.dill': digest1,
      });
      expect(bytes1, [10, 20, 30]);

      // Overwrite on disk, but pass the SAME digest1 via normalized key: should hit cache.
      dillFile.writeAsBytesSync([40, 50, 60]);
      final cachedHit = cache.dillBytesOf('./norm_mod/0.dill', {
        'norm_mod/0.dill': digest1,
      });
      expect(cachedHit, [10, 20, 30]);

      // Pass a new digest2: should invalidate and read new bytes from disk.
      final updated = cache.dillBytesOf('./norm_mod/0.dill', {
        'norm_mod/0.dill': digest2,
      });
      expect(updated, [40, 50, 60]);
    } finally {
      Directory.current = prevCwd;
    }
  });

  test('stripDillToOutline preserves member bodies and field initializers for legacy-class mixins compiled by kernel_worker', () async {
    final sdkDir = File(Platform.resolvedExecutable).parent.parent;
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final dartaotruntime = '${sdkDir.path}/bin/dartaotruntime$exeSuffix';
    final kernelWorker =
        '${sdkDir.path}/bin/snapshots/kernel_worker_aot.dart.snapshot';
    final platformDill = '${sdkDir.path}/lib/_internal/vm_platform_strong.dill';
    expect(File(dartaotruntime).existsSync(), isTrue);
    expect(File(kernelWorker).existsSync(), isTrue);
    expect(File(platformDill).existsSync(), isTrue);

    _write(
      'real_packages.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'legacy',
            'rootUri': '${_prefix}legacy',
            'packageUri': 'lib/',
            'languageVersion': '2.19',
          },
          {
            'name': 'modern',
            'rootUri': '${_prefix}modern',
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
          {
            'name': 'app',
            'rootUri': '${_prefix}app',
            'packageUri': 'lib/',
            'languageVersion': '3.0',
          },
        ],
      }),
    );

    Future<Uint8List> compileWithKernelWorker(
      String outName,
      List<String> sources, {
      List<String> inputSummaries = const [],
    }) async {
      final outPath = '${_root.path}/$outName';
      final res = await Process.run(dartaotruntime, [
        kernelWorker,
        '--target',
        'vm',
        '--dart-sdk-summary',
        platformDill,
        '--packages-file',
        '${_root.path}/real_packages.json',
        '--multi-root',
        _root.path,
        '--multi-root-scheme',
        'org-dartlang-bazel',
        '--no-summary-only',
        '--exclude-non-sources',
        for (final s in inputSummaries) ...['--input-summary', s],
        for (final s in sources) ...['--source', s],
        '--output',
        outPath,
      ]);
      expect(
        res.exitCode,
        0,
        reason: 'kernel_worker failed: ${res.stdout}\n${res.stderr}',
      );
      return File(outPath).readAsBytesSync();
    }

    // 1. Pre-3.0 library with a plain `class` (no `mixin` or `mixin class` modifier).
    _write(
      'legacy/lib/legacy.dart',
      'class LegacyMixin {\n'
          "  final String tag = 'legacy-tag-v1';\n"
          '  int count = 10;\n'
          "  String get label => '\$tag:\$count';\n"
          '  set bump(int delta) {\n'
          '    count += delta;\n'
          '  }\n'
          "  String describe(String who) => 'legacy-body-v1:\$who[\$label]';\n"
          '}\n'
          'class ChainedLegacy = Object with LegacyMixin;\n',
    );
    final legacyDillV1 = await compileWithKernelWorker('legacy_v1.dill', [
      'package:legacy/legacy.dart',
    ]);

    final err1 = StringBuffer();
    final legacyOutlineV1 = stripDillToOutline(legacyDillV1, errSink: err1);
    expect(err1.toString(), isEmpty);

    // Member bodies and mutable/final field initializers must survive in the outline.
    expect(
      _containsSubsequence(legacyOutlineV1, utf8.encode('legacy-body-v1:')),
      isTrue,
      reason: 'method body of a pre-3.0 class must survive in .koutline',
    );
    expect(
      _containsSubsequence(legacyOutlineV1, utf8.encode('legacy-tag-v1')),
      isTrue,
      reason: 'field initializer of a pre-3.0 class must survive in .koutline',
    );

    // 2. Body edit in the pre-3.0 class must change the outline bytes so dependents rebuild.
    _write(
      'legacy/lib/legacy.dart',
      'class LegacyMixin {\n'
          "  final String tag = 'legacy-tag-v1';\n"
          '  int count = 25;\n'
          "  String get label => '\$tag:\$count';\n"
          '  set bump(int delta) {\n'
          '    count += delta * 2;\n'
          '  }\n'
          "  String describe(String who) => 'legacy-body-v2:\$who[\$label]';\n"
          '}\n'
          'class ChainedLegacy = Object with LegacyMixin;\n',
    );
    final legacyDillV2 = await compileWithKernelWorker('legacy_v2.dill', [
      'package:legacy/legacy.dart',
    ]);
    final legacyOutlineV2 = stripDillToOutline(legacyDillV2);
    expect(
      legacyOutlineV2,
      isNot(equals(legacyOutlineV1)),
      reason: 'editing a member body or field initializer in a pre-3.0 class must change .koutline bytes',
    );

    // 3. Modern (Dart 3.0) library: plain class bodies are stripped, mixin / mixin class bodies survive.
    _write(
      'modern/lib/modern.dart',
      'class PlainModern {\n'
          '  int m = 777;\n'
          "  String plainBody() => 'plain-modern-secret-body';\n"
          '}\n'
          'mixin ModernMixin {\n'
          "  String mixinBody() => 'modern-mixin-kept-body';\n"
          '}\n'
          'mixin class ModernMixinClass {\n'
          "  String mixinClassBody() => 'modern-mixin-class-kept-body';\n"
          '}\n',
    );
    final modernDill = await compileWithKernelWorker('modern.dill', [
      'package:modern/modern.dart',
    ]);
    final modernOutline = stripDillToOutline(modernDill);
    expect(
      _containsSubsequence(
        modernOutline,
        utf8.encode('plain-modern-secret-body'),
      ),
      isFalse,
      reason: 'plain class in a Dart 3 library is not a mixin and its body must be stripped',
    );
    expect(
      _containsSubsequence(
        modernOutline,
        utf8.encode('modern-mixin-kept-body'),
      ),
      isTrue,
      reason: 'mixin declaration body must survive in .koutline',
    );
    expect(
      _containsSubsequence(
        modernOutline,
        utf8.encode('modern-mixin-class-kept-body'),
      ),
      isTrue,
      reason: 'mixin class declaration body must survive in .koutline',
    );

    // Also verify unknown format version fallback on a real kernel_worker dill.
    final futureModernDill = Uint8List.fromList(modernDill);
    ByteData.sublistView(futureModernDill).setUint32(4, 999);
    final futureOutlineErr = StringBuffer();
    expect(
      stripDillToOutline(futureModernDill, errSink: futureOutlineErr),
      equals(futureModernDill),
    );
    expect(
      futureOutlineErr.toString(),
      contains('unsupported kernel format version 999'),
    );
    final futureSrcErr = StringBuffer();
    expect(
      stripSourceCodeFromDill(futureModernDill, errSink: futureSrcErr),
      equals(futureModernDill),
    );
    expect(
      futureSrcErr.toString(),
      contains('unsupported kernel format version 999'),
    );

    // 4. Compile a Dart 3 consumer against the stripped legacy outline and run on the VM.
    final outlinePath = '${_root.path}/legacy_v1.koutline.dill';
    File(outlinePath).writeAsBytesSync(legacyOutlineV1);
    _write(
      'app/bin/main.dart',
      "import 'package:legacy/legacy.dart';\n"
          'class Thing with LegacyMixin {}\n'
          'class SubChained extends ChainedLegacy {}\n'
          'void main() {\n'
          '  final t = Thing()..bump = 5;\n'
          "  print(t.describe('thing'));\n"
          '  final s = SubChained()..bump = 2;\n'
          "  print(s.describe('chained'));\n"
          '}\n',
    );
    final appDill = await compileWithKernelWorker(
      'app.dill',
      ['${_prefix}app/bin/main.dart'],
      inputSummaries: [outlinePath],
    );
    final legacyKmodBytes = stripSourceCodeFromDill(legacyDillV1);
    final linkedPath = '${_root.path}/app_linked.dill';
    final linkedBytes = BytesBuilder(copy: false)
      ..add(legacyKmodBytes)
      ..add(appDill);
    File(linkedPath).writeAsBytesSync(linkedBytes.takeBytes());

    final runRes = await Process.run(Platform.resolvedExecutable, [linkedPath]);
    expect(
      runRes.exitCode,
      0,
      reason: 'VM run failed: ${runRes.stdout}\n${runRes.stderr}',
    );
    expect(
      (runRes.stdout as String).replaceAll('\r\n', '\n'),
      'legacy-body-v1:thing[legacy-tag-v1:15]\n'
      'legacy-body-v1:chained[legacy-tag-v1:12]\n',
    );
  });

  test('stripDillToOutline and stripSourceCodeFromDill reject unknown format versions with a diagnostic and return unstripped bytes', () {
    expect(supportedKernelFormatVersions, {138});
    for (final badVersion in [0, 120, 137, 139, 999]) {
      final dill = _buildMinimalFieldDill(formatVersion: badVersion);
      final snapshot = Uint8List.fromList(dill);

      final outlineErr = StringBuffer();
      final outlineResult = stripDillToOutline(dill, errSink: outlineErr);
      expect(
        outlineResult,
        equals(snapshot),
        reason:
            'stripDillToOutline must return unstripped bytes for version $badVersion',
      );
      expect(
        outlineErr.toString(),
        allOf(
          contains('unsupported kernel format version $badVersion'),
          contains('falling back to unstripped dill'),
        ),
      );

      final srcErr = StringBuffer();
      final srcResult = stripSourceCodeFromDill(dill, errSink: srcErr);
      expect(
        srcResult,
        equals(snapshot),
        reason:
            'stripSourceCodeFromDill must return unstripped bytes for version $badVersion',
      );
      expect(
        srcErr.toString(),
        allOf(
          contains('unsupported kernel format version $badVersion'),
          contains('falling back to unstripped dill'),
        ),
      );
    }

    // Multi-component dill where the second component has an unknown format version:
    // stripDillToOutline must fall back to the full unstripped input bytes.
    final validPart = _buildMinimalFieldDill();
    final invalidPart = _buildMinimalFieldDill(formatVersion: 999);
    final combined = Uint8List.fromList([...validPart, ...invalidPart]);
    final combinedSnapshot = Uint8List.fromList(combined);
    final multiErr = StringBuffer();
    final multiResult = stripDillToOutline(combined, errSink: multiErr);
    expect(multiResult, equals(combinedSnapshot));
    expect(
      multiErr.toString(),
      contains('unsupported kernel format version 999'),
    );
  });
}
