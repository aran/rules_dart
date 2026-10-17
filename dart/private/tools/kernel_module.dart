// Compiles one kernel module with `kernel_worker`. See `kernel_module_action` in
// `dart/private/dart_kernel.bzl`.
//
// A module compiles the sources its `dart_library` declares, except the files that
// cannot compile for the VM. Which files those are is decided before compiling,
// from the import graph, by reading each source's directives:
//
//  * A file that imports or exports a `dart:` library the VM does not have
//    (`dart:html`, `dart:js_interop`, ...) is excluded.
//  * A file that imports or exports a `package:` URI whose package is not in the
//    module's package config is excluded, since the module cannot resolve it.
//  * A file with a `part` directive whose part is not one of the module's own
//    sources is excluded, since the library cannot compile without its part.
//  * A file that imports or exports an excluded file is excluded. A `part` shares
//    its library's verdict.
//  * A conditional import takes its first `dart.library.X` alternative for a VM
//    library X, and its default URI otherwise.
//  * The VM libraries are those of the `vm` platform in the SDK's `libraries.json`,
//    following its `include`s.
//  * A source that a dependency module already defines is not compiled again. The
//    kernels the module links against define it, and the module's dependents link
//    to that kernel.
//  * An excluded file is listed in the module's `.vm_excluded.txt` sidecar. A
//    dependent module reads the sidecars of its whole closure, so the files that
//    import an excluded file are excluded too. A dependent that lists the excluded
//    file among its own sources compiles its own copy, if it can. An excluded file
//    that some module of the closure defines is not excluded for the closure at all.
//
// The module's output is a directory. It holds one kernel per strongly connected
// component of its own sources (libraries that import each other compile together,
// and a part belongs to its library), and an `index.json` that lists them: each
// kernel's file, the keys of the libraries it defines, and the keys it imports. A
// component compiles against only the kernels it reaches, passed as `--input-summary`,
// and a kernel is written after every kernel it imports.
//
// When `--output-outline` is given, each compiled component is also stripped to a
// deterministic outline `.dill` (`stripDillToOutline`) in the `.koutline` directory
// for downstream `--input-summary` compiles, while the `.kmod` directory keeps the
// full component with embedded source text stripped (`stripSourceCodeFromDill`). Any
// class that can be used as a mixin (`mixin`, `mixin class`, and every class in a
// library whose language version is below 3.0) keeps its member bodies and field
// initializers in `.koutline`. Both strippers check the 32-bit kernel format version
// in the header (accepting version 138, Dart 3.13.x) and log a diagnostic to `stderr`
// while falling back to the unstripped `.dill` bytes on any other version.
//
// A dependent module names its dependencies' directories with `--input-kmod`. It reads
// their indexes, and each component compiles against the kernels it reaches through
// them.
//
// The remaining sources compile with `--exclude-non-sources`, so a kernel holds its
// own libraries and nothing it links against. An error from one of them is real, and
// fails the action with the compiler's output. The one exception is a safety net: an
// error that can be blamed on an own source drops that source and its importers, and
// the module compiles once more. Any other error fails at once.
//
// An executable's entry module compiles from source every file it reaches that the
// closure excludes and no module defines, so the compiler reports the genuine VM error
// exactly as a whole-program compile would. It has no safety net. Its kernel is linked,
// with the kernels it reaches, by `kernel_link`.
//
// With `--persistent_worker` this is a Bazel persistent worker. It keeps one
// `kernel_worker` child running for its requests, retries included. When the child
// cannot be trusted, the child is killed, a new one starts, and the request is sent to
// it once more. That is after the child dies, after a request runs past the timeout
// (15 minutes, or `--request-timeout-seconds=N` for a test), after bytes that are not
// the answer to the request, and after a crash, since a crashed child never answers its
// next request. A second failure fails the action, with both attempts' output. Without
// the flag it runs one compile. Either way it prints nothing on success, and on a
// failure it prints the full diagnostics.
//
// The worker protocol is spoken directly, as a length-prefixed `WorkRequest` and
// `WorkResponse`, rather than through `package:bazel_worker`. That package is a
// `dart_library`, and every `dart_library` carries this tool as an attribute, so
// depending on it would make a cycle.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dill_outline.dart';

const _kernelWorkerFlag = '--kernel-worker';
const _dartaotruntimeFlag = '--dartaotruntime';
const _persistentFlag = '--persistent_worker';

// Flags this tool consumes. `kernel_worker` never sees them.
const _excludedOutputFlag = '--excluded-output';
const _closureExcludedFlag = '--closure-excluded';
const _librariesJsonFlag = '--libraries-json';
const _librariesPlatformFlag = '--libraries-platform';
const _extraLibraryFlag = '--extra-library';
const _inputKmodFlag = '--input-kmod';
const _outputOutlineFlag = '--output-outline';

/// The file in each module directory that lists its kernels.
const _indexName = 'index.json';
const _noDropFlag = '--no-drop';
const _packagesFlag = '--packages-file';
const _multiRootFlag = '--multi-root';
const _multiRootSchemeFlag = '--multi-root-scheme';

const _defaultMultiRootPrefix = 'org-dartlang-bazel:///';

/// `<path>:<line>:<col>: Error: <message>`, one per located diagnostic.
final _errorLine = RegExp(r'^(.+?):(\d+):(\d+): Error: (.*)$', multiLine: true);

/// The `bazel-out/<config>/bin/` prefix a diagnostic may give a generated file.
final _bazelOutPrefix = RegExp(r'^(?:\./)?bazel-out/[^/]+/bin/');

Future<void> main(List<String> argv) async {
  var persistent = false;
  String? kernelWorker;
  String? dartaotruntime;
  Duration? requestTimeout;
  final rest = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == _persistentFlag) {
      persistent = true;
    } else if (arg.startsWith(_requestTimeoutFlag)) {
      final seconds = int.tryParse(arg.substring(_requestTimeoutFlag.length));
      if (seconds == null || seconds <= 0) {
        stderr.writeln(
          'kernel_module: $arg is not a positive number of seconds.',
        );
        exitCode = 64;
        return;
      }
      requestTimeout = Duration(seconds: seconds);
    } else if (arg == _kernelWorkerFlag) {
      kernelWorker = argv[++i];
    } else if (arg == _dartaotruntimeFlag) {
      dartaotruntime = argv[++i];
    } else {
      rest.add(arg);
    }
  }
  if (kernelWorker == null || dartaotruntime == null) {
    stderr.writeln(
      'kernel_module: $_kernelWorkerFlag and $_dartaotruntimeFlag are required.',
    );
    exitCode = 64;
    return;
  }
  if (persistent) {
    await _serve(dartaotruntime, kernelWorker, requestTimeout);
    // Exit explicitly. Streams of the `kernel_worker` child stay subscribed after
    // it is killed, and would otherwise keep this process alive past its work.
    await stdout.flush();
    exit(0);
  }
  final args = await _expandParamFiles(rest);
  final log = StringBuffer();
  final code = await compileModule(
    args,
    _OneShot(dartaotruntime, kernelWorker),
    log,
    const [],
  );
  if (code != 0) {
    stderr.write(log);
  }
  await stderr.flush();
  exit(code);
}

/// Serves Bazel `WorkRequest`s until stdin closes.
Future<void> _serve(
  String dartaotruntime,
  String kernelWorker,
  Duration? requestTimeout,
) async {
  final requests = _Frames(stdin);
  final compiler = _Persistent(
    dartaotruntime,
    kernelWorker,
    requestTimeout: requestTimeout,
  );
  try {
    while (true) {
      final frame = await requests.next();
      if (frame == null) break;
      // Every request is answered, even one that fails to decode or compile:
      // a worker that closes stdout without a `WorkResponse` fails the action
      // with no diagnostics at all.
      final log = StringBuffer();
      var code = 1;
      var requestId = 0;
      try {
        final request = _WorkRequest.decode(frame);
        requestId = request.requestId;
        code = await compileModule(
          request.arguments,
          compiler,
          log,
          request.inputs,
        );
      } catch (error, stack) {
        log.writeln('kernel_module: $error\n$stack');
      }
      stdout.add(_frame(_encodeResponse(code, log.toString(), requestId)));
      await stdout.flush();
    }
  } finally {
    await compiler.close();
  }
}

/// Compiles one module, or the entry module when `--no-drop` is set.
///
/// The module's directory receives one kernel per strongly connected component of its
/// own sources, and an `index.json` that lists them. Returns 0 on success. Returns 1
/// when a compile fails, with the compiler's output in `log`. Returns 64 when an
/// argument is missing.
///
/// Public so that a test can drive the planner with a [ModuleCompiler] that records its
/// arguments, without a `kernel_worker`.
Future<int> compileModule(
  List<String> rawArgs,
  ModuleCompiler compiler,
  StringBuffer log,
  List<Uint8List> inputs,
) async {
  final base = <String>[];
  final sources = <String>[];
  final multiRoots = <String>[];
  final closureExcluded = <String>[];
  final inputKmods = <String>[];
  final extraLibraries = <String>[];
  String? excludedPath;
  String? output;
  String? outputOutline;
  String? packagesFile;
  String? librariesJson;
  var librariesPlatform = 'vm';
  var multiRootPrefix = _defaultMultiRootPrefix;
  var noDrop = false;
  for (var i = 0; i < rawArgs.length; i++) {
    final arg = rawArgs[i];
    if (arg == '--source') {
      sources.add(rawArgs[++i]);
    } else if (arg == '--output') {
      output = rawArgs[++i];
    } else if (arg == _outputOutlineFlag) {
      outputOutline = rawArgs[++i];
    } else if (arg == _excludedOutputFlag) {
      excludedPath = rawArgs[++i];
    } else if (arg == _closureExcludedFlag) {
      closureExcluded.add(rawArgs[++i]);
    } else if (arg == _inputKmodFlag) {
      inputKmods.add(rawArgs[++i]);
    } else if (arg == _librariesJsonFlag) {
      librariesJson = rawArgs[++i];
    } else if (arg == _librariesPlatformFlag) {
      librariesPlatform = rawArgs[++i];
    } else if (arg == _extraLibraryFlag) {
      extraLibraries.add(rawArgs[++i]);
    } else if (arg == _noDropFlag) {
      noDrop = true;
    } else if (arg == '--input-linked') {
      log.writeln(
        'kernel_module: --input-linked is not accepted; pass $_inputKmodFlag.',
      );
      return 64;
    } else {
      if (arg == _packagesFlag) packagesFile = rawArgs[i + 1];
      if (arg == _multiRootFlag) multiRoots.add(rawArgs[i + 1]);
      if (arg == _multiRootSchemeFlag) {
        multiRootPrefix = '${rawArgs[i + 1]}:///';
      }
      base.add(arg);
    }
  }
  if (excludedPath == null ||
      output == null ||
      packagesFile == null ||
      librariesJson == null) {
    log.writeln(
      'kernel_module: $_excludedOutputFlag, $_librariesJsonFlag, --output and '
      '$_packagesFlag are required.',
    );
    return 64;
  }
  final files = _Files(multiRoots.isEmpty ? const ['.'] : multiRoots);
  final roots = await _packageRoots(packagesFile, multiRootPrefix);
  final closure = await _readExcluded(closureExcluded, roots, multiRootPrefix);
  final vm = vmLibraries(
    jsonDecode(await File(librariesJson).readAsString())
        as Map<String, dynamic>,
    platform: librariesPlatform,
    extraLibraries: extraLibraries,
  );
  // Every kernel the closure indexes, by the key of each library it defines.
  final graph = <String, _Node>{};
  for (final dir in inputKmods) {
    if (!await _readIndex(dir, graph, log)) return 1;
  }
  await Directory(output).create(recursive: true);
  if (outputOutline != null) {
    await Directory(outputOutline).create(recursive: true);
  }

  // A file that a dependency module defines is linked from that module, so this module
  // neither compiles it nor excludes it. An excluded file in the closure counts only
  // while no module of the closure defines it: then the module that defines it is the
  // copy the executable links.
  final inherited = <String, String>{
    for (final entry in closure.entries)
      if (!graph.containsKey(entry.key)) entry.key: entry.value,
  };
  final own = <String>[
    for (final uri in sources)
      if (!_definedBy(uri, graph, roots, multiRootPrefix)) uri,
  ];

  if (noDrop) {
    final entry = await _entrySources(
      sources,
      inherited,
      roots,
      files,
      vm,
      multiRootPrefix,
    );
    const dill = 'entry.dill';
    final outcome = await compiler.run([
      ...base,
      for (final d in neededDills(entry.imports, graph)) ...[
        '--input-summary',
        d,
      ],
      for (final source in entry.uris) ...['--source', source],
      '--output',
      '$output/$dill',
    ], inputs);
    if (outcome.exitCode != 0) {
      log.write(outcome.output);
      return 1;
    }
    final entrySccs = [
      _Scc(dill: dill, keys: const [], uris: const [], imports: entry.imports),
    ];
    await _writeIndex(output, entrySccs);
    if (outputOutline != null) {
      final fullFile = File('$output/$dill');
      if (await fullFile.exists()) {
        final outlineBytes = stripDillToOutline(await fullFile.readAsBytes());
        await File('$outputOutline/$dill').writeAsBytes(outlineBytes);
      }
      await _writeIndex(outputOutline, entrySccs);
    }
    await File(excludedPath).writeAsString('');
    return 0;
  }

  final keys = <String, String>{};
  final plan = _Plan();
  for (final uri in own) {
    final key = _keyOfUri(uri, roots, multiRootPrefix);
    if (key == null) continue;
    keys[uri] = key;
    plan.addOwn(key, uri);
  }
  await _planImports(plan, keys, inherited, roots, files, vm, log);

  var remaining = [
    for (final uri in own)
      if (!plan.isExcluded(keys[uri])) uri,
  ];
  var retried = false;
  var sccs = <_Scc>[];
  while (true) {
    sccs = _componentsOf(remaining, keys, plan);
    // The kernels this attempt has written, by key. A later component links to them.
    final local = Map<String, _Node>.of(graph);
    ModuleOutcome? failure;
    var failedUris = const <String>[];
    for (final scc in sccs) {
      final dillPath = '$output/${scc.dill}';
      final outcome = await compiler.run([
        ...base,
        for (final d in neededDills(scc.imports, local)) ...[
          '--input-summary',
          d,
        ],
        for (final uri in scc.uris) ...['--source', uri],
        '--output',
        dillPath,
      ], inputs);
      if (outcome.exitCode != 0) {
        failure = outcome;
        failedUris = scc.uris;
        break;
      }
      var nodeDill = dillPath;
      final dillFile = File(dillPath);
      if (await dillFile.exists()) {
        final rawBytes = await dillFile.readAsBytes();
        if (outputOutline != null) {
          final outlineBytes = stripDillToOutline(rawBytes);
          nodeDill = '$outputOutline/${scc.dill}';
          await File(nodeDill).writeAsBytes(outlineBytes);
        }
        await dillFile.writeAsBytes(_stripSourceCodeFromDill(rawBytes));
      }
      final node = _Node(nodeDill, scc.imports);
      for (final key in scc.keys) {
        local[key] = node;
      }
    }
    if (failure == null) break;
    // The one retry: drop the own sources that failed, and their importers. The
    // components are then formed again from what remains.
    final verdict = _attribute(
      failure.output,
      failedUris,
      roots,
      multiRootPrefix,
    );
    if (retried ||
        verdict.unattributed ||
        verdict.outside ||
        verdict.failing.isEmpty) {
      log.write(failure.output);
      return 1;
    }
    retried = true;
    plan.exclude({
      for (final entry in verdict.failing.entries)
        entry.key: 'compile error: ${entry.value}',
    });
    remaining = [
      for (final uri in remaining)
        if (!plan.isExcluded(keys[uri])) uri,
    ];
  }
  await _writeIndex(output, sccs);
  if (outputOutline != null) {
    await _writeIndex(outputOutline, sccs);
  }

  // Written even when nothing is excluded: the sidecar is a declared output. Its
  // `#` line is a count for the build log, and each excluded source is listed under
  // its `package:` URI and its multi-root URI, with the reason.
  final lines = StringBuffer()
    ..writeln(
      '# ${remaining.length} of ${own.length} sources compile; the others '
      'are excluded for the VM.',
    );
  for (final uri in own) {
    final key = keys[uri];
    final reason = plan.reasonOf(key);
    if (key == null || reason == null) continue;
    lines.writeln('$uri\t$reason');
    if (!uri.startsWith(multiRootPrefix)) {
      lines.writeln('$multiRootPrefix$key\t$reason');
    }
  }
  await File(excludedPath).writeAsString(lines.toString());
  return 0;
}

/// One kernel a module writes: the sources it compiles, and the keys it imports.
class _Scc {
  _Scc({
    required this.dill,
    required this.keys,
    required this.uris,
    required this.imports,
  });

  /// The file name within the module's directory.
  final String dill;

  /// The keys of the libraries (and parts) this kernel defines, sorted.
  final List<String> keys;

  /// The URIs the kernel compiles each of `keys` under.
  final List<String> uris;

  /// The keys this kernel imports or exports from outside itself, sorted.
  final List<String> imports;
}

/// A kernel an index names: its file, and the keys it imports.
class _Node {
  _Node(this.dill, this.imports);

  final String dill;
  final List<String> imports;
}

/// The components of the remaining own sources, dependencies first. Each is one
/// kernel, named by its position: `<n>.dill`. Libraries that import each other, and
/// the parts of a library, form one component.
List<_Scc> _componentsOf(
  List<String> remaining,
  Map<String, String> keys,
  _Plan plan,
) {
  final uriOf = <String, String>{};
  for (final uri in remaining) {
    uriOf.putIfAbsent(keys[uri] ?? 'uri:$uri', () => uri);
  }
  final nodes = uriOf.keys.toList()..sort();
  final members = uriOf.keys.toSet();
  Iterable<String> successors(String key) => plan
      .importsOf(key)
      .where((target) => target != key && members.contains(target));
  final components = stronglyConnected(nodes, successors);
  return [
    for (var i = 0; i < components.length; i++)
      _sccOf('$i.dill', components[i], uriOf, plan),
  ];
}

_Scc _sccOf(
  String dill,
  List<String> keys,
  Map<String, String> uriOf,
  _Plan plan,
) {
  final own = keys.toSet();
  final imports = <String>{
    for (final key in keys) ...plan.importsOf(key),
  }.where((target) => !own.contains(target)).toList()..sort();
  return _Scc(
    dill: dill,
    keys: keys,
    uris: [for (final key in keys) uriOf[key]!],
    imports: imports,
  );
}

/// The strongly connected components of a graph, each sorted, in an order where every
/// component follows the components it reaches. Tarjan's algorithm emits a component
/// once everything it reaches is emitted, which gives that order directly. Nodes and
/// successors are visited in sorted order, so the same graph always gives the same
/// components in the same order.
List<List<String>> stronglyConnected(
  List<String> nodes,
  Iterable<String> Function(String) successors,
) {
  final index = <String, int>{};
  final low = <String, int>{};
  final onStack = <String>{};
  final stack = <String>[];
  final out = <List<String>>[];
  void visit(String v) {
    index[v] = low[v] = index.length;
    stack.add(v);
    onStack.add(v);
    for (final w in successors(v)) {
      if (!index.containsKey(w)) {
        visit(w);
        final lowW = low[w]!;
        if (lowW < low[v]!) low[v] = lowW;
      } else if (onStack.contains(w)) {
        final indexW = index[w]!;
        if (indexW < low[v]!) low[v] = indexW;
      }
    }
    if (low[v] == index[v]) {
      final component = <String>[];
      String w;
      do {
        w = stack.removeLast();
        onStack.remove(w);
        component.add(w);
      } while (w != v);
      out.add(component..sort());
    }
  }

  for (final node in nodes) {
    if (!index.containsKey(node)) visit(node);
  }
  return out;
}

/// The kernels a dependency module needs to compile against: every kernel reached from
/// `roots` through the imports of the kernels they name. Sorted, so the arguments of
/// a compile do not change from one build to the next.
List<String> neededDills(Iterable<String> roots, Map<String, _Node> graph) {
  final dills = <String>{};
  final visited = <String>{};
  final queue = Queue<String>.of(roots);
  while (queue.isNotEmpty) {
    final key = queue.removeFirst();
    if (!visited.add(key)) continue;
    final node = graph[key];
    if (node == null) continue;
    if (dills.add(node.dill)) queue.addAll(node.imports);
  }
  return dills.toList()..sort();
}

/// Adds the kernels that the module directory `dir` indexes to `graph`, by each key
/// they define. Returns false, after saying why, when the index is missing.
Future<bool> _readIndex(
  String dir,
  Map<String, _Node> graph,
  StringBuffer log,
) async {
  final file = File('$dir/$_indexName');
  if (!await file.exists()) {
    log.writeln('kernel_module: $dir has no $_indexName.');
    return false;
  }
  final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>()) {
    final node = _Node(
      '$dir/${scc['dill']}',
      (scc['imports'] as List).cast<String>(),
    );
    for (final key in (scc['defines'] as List).cast<String>()) {
      graph.putIfAbsent(key, () => node);
    }
  }
  return true;
}

Future<void> _writeIndex(String dir, List<_Scc> sccs) async {
  final json = const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'sccs': [
      for (final scc in sccs)
        {'dill': scc.dill, 'defines': scc.keys, 'imports': scc.imports},
    ],
  });
  await File('$dir/$_indexName').writeAsString('$json\n');
}

/// The import graph of a module's own sources, and which of them are excluded.
class _Plan {
  /// The URI each own source was given, by key.
  final Map<String, String> _uriOf = {};

  /// The own sources that import each own source, by key, in the order found.
  final Map<String, List<String>> _importers = {};

  /// The excluded own sources, by key, with the reason. In the order excluded.
  final Map<String, String> _excluded = {};

  /// What each source imports or exports, by key: own sources and dependencies alike.
  final Map<String, Set<String>> _imports = {};

  void addOwn(String key, String uri) => _uriOf.putIfAbsent(key, () => uri);

  bool isOwn(String key) => _uriOf.containsKey(key);

  /// Records that `importer` imports or exports `imported`, an own source.
  void addImporter({required String imported, required String importer}) {
    (_importers[imported] ??= []).add(importer);
  }

  /// Records that `importer` imports or exports `target`, whether or not it is own.
  void addImport({required String importer, required String target}) {
    (_imports[importer] ??= {}).add(target);
  }

  /// The keys `key` imports or exports, sorted.
  List<String> importsOf(String key) =>
      (_imports[key] ?? const <String>{}).toList()..sort();

  bool isExcluded(String? key) => key != null && _excluded.containsKey(key);

  String? reasonOf(String? key) => key == null ? null : _excluded[key];

  /// Excludes each seed, then every own source that imports an excluded one.
  void exclude(Map<String, String> seeds) {
    final queue = Queue<String>();
    seeds.forEach((key, reason) {
      if (isOwn(key) && !_excluded.containsKey(key)) {
        _excluded[key] = reason;
        queue.add(key);
      }
    });
    while (queue.isNotEmpty) {
      final key = queue.removeFirst();
      for (final importer in _importers[key] ?? const <String>[]) {
        if (_excluded.containsKey(importer)) continue;
        _excluded[importer] = 'imports ${_uriOf[key]}, which is excluded';
        queue.add(importer);
      }
    }
  }
}

/// Records each own source's imports in `plan`, and excludes the sources a VM
/// cannot compile: those that import a `dart:` library the VM lacks, a `package:` that
/// the module's config does not name, a part that is not an own source, or a file that
/// `inherited` lists as excluded.
Future<void> _planImports(
  _Plan plan,
  Map<String, String> keys,
  Map<String, String> inherited,
  Map<String, _PackageRoot> roots,
  _Files files,
  Set<String> vm,
  StringBuffer log,
) async {
  final direct = <String, String>{};
  for (final key in keys.values) {
    final text = await files.read(key);
    final scan = text == null ? null : scanDirectives(text, vm);
    if (scan == null) {
      // Not readable here, or not a directive prologue the scanner can follow. The
      // compiler decides, and a failure in it is attributed or fails the action.
      log.writeln('kernel_module: could not read the directives of $key.');
      continue;
    }
    for (final ref in scan.refs) {
      if (ref.uri.startsWith('dart:')) {
        if (!vm.contains(ref.uri.substring('dart:'.length))) {
          direct.putIfAbsent(key, () => '${ref.uri} is not a VM library');
        }
        continue;
      }
      final target = _resolveUri(ref.uri, key, roots);
      if (target == null) {
        // A `package:` the module's config does not name. Other schemes are not Dart
        // sources this module can read, and resolve to null without a rule of their own.
        if (ref.uri.startsWith('package:')) {
          direct.putIfAbsent(
            key,
            () => '${ref.uri} names a package this module does not have',
          );
        }
        continue;
      }
      plan.addImport(importer: key, target: target);
      if (ref.isPart && !plan.isOwn(target)) {
        direct.putIfAbsent(
          key,
          () => 'its part ${ref.uri} is not an input of this module',
        );
        continue;
      }
      if (plan.isOwn(target)) {
        plan.addImporter(imported: target, importer: key);
        // A part follows its library both ways.
        if (ref.isPart) {
          plan.addImporter(imported: key, importer: target);
          plan.addImport(importer: target, target: key);
        }
      } else if (inherited.containsKey(target)) {
        direct.putIfAbsent(key, () => 'imports ${ref.uri}, which is excluded');
      }
    }
  }
  plan.exclude(direct);
}

/// Whether the source at `uri` is one a module of the closure defines, so that this
/// module need not compile it. `graph` holds the keys the closure's modules define.
bool _definedBy(
  String uri,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final key = _keyOfUri(uri, roots, multiRootPrefix);
  return key != null && graph.containsKey(key);
}

/// What the entry module compiles, and what it imports.
class _EntrySources {
  _EntrySources(this.uris, this.imports);

  /// The URIs the entry compiles: its own sources, and each excluded file it reaches.
  final List<String> uris;

  /// The keys of every library the entry's sources import, sorted. The entry links
  /// against the kernels these reach.
  final List<String> imports;
}

/// The sources the entry module compiles: its own, and each excluded file it reaches.
/// An excluded file is compiled from source here, so the compiler reports its genuine
/// VM error. Every other file it reaches is in a module.
class _EntryEdge {
  _EntryEdge(this.from, this.uri, this.target);

  final String from;
  final String uri;
  final String target;
}

Future<_EntrySources> _entrySources(
  List<String> sources,
  Map<String, String> closure,
  Map<String, _PackageRoot> roots,
  _Files files,
  Set<String> vm,
  String multiRootPrefix,
) async {
  final out = <String>[];
  final ownUris = <String, String>{};
  final imports = <String>{};
  final seen = <String>{};
  final queue = Queue<String>();
  final edges = <_EntryEdge>[];
  for (final uri in sources) {
    final key = _keyOfUri(uri, roots, multiRootPrefix);
    if (key == null) {
      out.add(uri);
    } else {
      ownUris.putIfAbsent(key, () => uri);
      if (seen.add(key)) queue.add(key);
    }
  }
  while (queue.isNotEmpty) {
    final key = queue.removeFirst();
    final text = await files.read(key);
    final scan = text == null ? null : scanDirectives(text, vm);
    if (scan == null) continue;
    for (final ref in scan.refs) {
      if (ref.uri.startsWith('dart:')) continue;
      final target = _resolveUri(ref.uri, key, roots, multiRootPrefix);
      if (target == null) continue;
      edges.add(_EntryEdge(key, ref.uri, target));
      imports.add(target);
      if (!seen.add(target)) continue;
      final uri = closure[target];
      if (uri == null) continue;
      ownUris.putIfAbsent(target, () => uri);
      queue.add(target);
    }
  }
  imports.removeAll(ownUris.keys);

  final usedAsRaw = <String>{};
  final usedAsPackage = <String>{};
  ownUris.forEach((key, uri) {
    final pkgUri = _packageUriOf(key, uri, roots);
    if (pkgUri == uri) {
      usedAsRaw.add(key);
    } else if (uri.startsWith('package:')) {
      usedAsPackage.add(key);
    }
  });
  for (final edge in edges) {
    if (!ownUris.containsKey(edge.target)) continue;
    if (edge.uri.startsWith('package:')) {
      usedAsPackage.add(edge.target);
    } else if (edge.uri.startsWith(multiRootPrefix)) {
      usedAsRaw.add(edge.target);
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (final edge in edges) {
      if (!ownUris.containsKey(edge.target) || edge.uri.contains(':')) continue;
      if (usedAsRaw.contains(edge.from) && usedAsRaw.add(edge.target)) {
        changed = true;
      }
    }
  }
  ownUris.forEach((key, uri) {
    if (_packageUriOf(key, uri, roots) != uri && !usedAsRaw.contains(key)) {
      usedAsPackage.add(key);
    }
  });
  changed = true;
  while (changed) {
    changed = false;
    for (final edge in edges) {
      if (!ownUris.containsKey(edge.target) || edge.uri.contains(':')) continue;
      final targetUri = ownUris[edge.target]!;
      if (usedAsPackage.contains(edge.from) &&
          _packageUriOf(edge.target, targetUri, roots) != targetUri &&
          usedAsPackage.add(edge.target)) {
        changed = true;
      }
    }
  }
  ownUris.forEach((key, uri) {
    final pkgUri = _packageUriOf(key, uri, roots);
    if (pkgUri == uri) {
      out.add(uri);
      return;
    }
    if (usedAsPackage.contains(key) || !usedAsRaw.contains(key)) {
      out.add(pkgUri);
    }
    if (usedAsRaw.contains(key)) {
      final rawUri = uri.startsWith(multiRootPrefix)
          ? uri
          : '$multiRootPrefix$key';
      if (rawUri != pkgUri) out.add(rawUri);
    }
  });
  return _EntrySources(out, imports.toList()..sort());
}

/// The `package:` URI of the file with `key`, when a package names it under its
/// `lib/`, and otherwise `uri`. An importer names such a library by its `package:`
/// URI, and `--exclude-non-sources` emits a library only under the URI it was given,
/// so an entry compiles its own `lib/` files under that URI too.
String _packageUriOf(String key, String uri, Map<String, _PackageRoot> roots) {
  String? best;
  var bestLength = -1;
  roots.forEach((name, root) {
    final prefix = '${root.path}${root.packageUri}';
    if (key.startsWith(prefix) && prefix.length > bestLength) {
      best = 'package:$name/${key.substring(prefix.length)}';
      bestLength = prefix.length;
    }
  });
  return best ?? uri;
}

/// The result of attributing a failing compile's diagnostics to own sources.
class _Verdict {
  const _Verdict({
    this.failing = const {},
    this.outside = false,
    this.unattributed = false,
  });

  /// Each own source with an error, by key, mapped to its first error message.
  final Map<String, String> failing;

  /// True when an error is located in a file that is not one of the own sources.
  final bool outside;

  /// True when a diagnostic names no location the tool can read.
  final bool unattributed;
}

_Verdict _attribute(
  String output,
  List<String> uris,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final keyOfSpelling = <String, String>{};
  for (final uri in uris) {
    final key = _keyOfUri(uri, roots, multiRootPrefix);
    if (key == null) continue;
    for (final spelling in _spellings(uri, key)) {
      keyOfSpelling.putIfAbsent(spelling, () => key);
    }
  }
  final failing = <String, String>{};
  var outside = false;
  var located = 0;
  for (final match in _errorLine.allMatches(output)) {
    located++;
    final key = _lookup(keyOfSpelling, match.group(1)!, multiRootPrefix);
    if (key == null) {
      outside = true;
      continue;
    }
    failing.putIfAbsent(key, () => match.group(4)!);
  }
  final errorLines = output
      .split('\n')
      .where((line) => line.startsWith('Error: ') || line.contains(': Error: '))
      .length;
  return _Verdict(
    failing: failing,
    outside: outside,
    unattributed: located == 0 || errorLines != located,
  );
}

/// The key of the first spelling of `path` that `spellings` knows.
String? _lookup(
  Map<String, String> spellings,
  String path,
  String multiRootPrefix,
) {
  for (final spelling in [
    path,
    _stripPrefix(path, multiRootPrefix),
    path.replaceFirst(_bazelOutPrefix, ''),
  ]) {
    if (spelling == null) continue;
    final key = spellings[spelling];
    if (key != null) return key;
  }
  return null;
}

/// Every name a diagnostic might use for a source: its key, and its URI.
Iterable<String> _spellings(String uri, String key) sync* {
  yield key;
  yield uri;
}

/// The path after `multiRootPrefix`, or null for any other URI.
String? _stripPrefix(
  String uri, [
  String multiRootPrefix = _defaultMultiRootPrefix,
]) {
  if (uri.startsWith(multiRootPrefix)) {
    return uri.substring(multiRootPrefix.length);
  }
  return null;
}

/// The key of a source or a library: the path it has under the multi-root
/// directories, without the scheme. Null for a URI this module cannot name, such as
/// a `dart:` library or a `package:` whose package it does not list.
String? _keyOfUri(
  String uri,
  Map<String, _PackageRoot> roots, [
  String multiRootPrefix = _defaultMultiRootPrefix,
]) {
  final stripped = _stripPrefix(uri, multiRootPrefix);
  if (stripped != null) return _normalize(stripped);
  if (!uri.startsWith('package:')) return null;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  final root = roots[rest.substring(0, slash)];
  if (root == null) return null;
  return _normalize(
    '${root.path}${root.packageUri}${rest.substring(slash + 1)}',
  );
}

/// The key a URI in a file named `fromKey` refers to, or null when the URI is not
/// one this module can name.
String? _resolveUri(
  String uri,
  String fromKey,
  Map<String, _PackageRoot> roots, [
  String multiRootPrefix = _defaultMultiRootPrefix,
]) {
  if (uri.startsWith('package:') || uri.startsWith(multiRootPrefix)) {
    return _keyOfUri(uri, roots, multiRootPrefix);
  }
  if (uri.contains(':')) return null;
  final slash = fromKey.lastIndexOf('/');
  final dir = slash < 0 ? '' : fromKey.substring(0, slash + 1);
  return _normalize('$dir$uri');
}

/// `path` without empty and `.` segments, with each `..` applied.
String _normalize(String path) {
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

/// Reads the files of a module's sources from the multi-root directories.
class _Files {
  _Files(this._roots);

  final List<String> _roots;
  final Map<String, String?> _cache = {};

  /// The text of the file with `key`, or null when no root has it.
  Future<String?> read(String key) async {
    if (_cache.containsKey(key)) return _cache[key];
    String? text;
    for (final root in _roots) {
      final file = File(root == '.' ? key : '$root/$key');
      if (await file.exists()) {
        text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
        break;
      }
    }
    return _cache[key] = text;
  }
}

/// The excluded files the sidecars list, by key. Each maps to its `package:` URI
/// when a sidecar gives one, and otherwise to its multi-root URI.
Future<Map<String, String>> _readExcluded(
  List<String> paths,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) async {
  final out = <String, String>{};
  for (final path in paths) {
    for (final line in await File(path).readAsLines()) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final uri = line.split('\t').first;
      final key = _keyOfUri(uri, roots, multiRootPrefix);
      if (key == null) continue;
      final known = out[key];
      if (known == null ||
          (uri.startsWith('package:') && !known.startsWith('package:'))) {
        out[key] = uri;
      }
    }
  }
  return out;
}

/// The libraries of `platform` in a `libraries.json`, plus `extraLibraries`, by bare
/// name. The platform's `include`s count too (`vm` inherits `vm_common`), and a
/// platform other than `vm` also inherits `vm` when `libraries.json` defines it.
Set<String> vmLibraries(
  Map<String, dynamic> json, {
  String platform = 'vm',
  Iterable<String> extraLibraries = const [],
}) {
  final names = <String>{};
  final seen = <String>{};
  void collect(String target) {
    if (!seen.add(target)) return;
    final entry = json[target];
    if (entry is! Map) return;
    final libraries = entry['libraries'];
    if (libraries is Map) {
      for (final name in libraries.keys) {
        final text = name.toString();
        names.add(
          text.startsWith('dart:') ? text.substring('dart:'.length) : text,
        );
      }
    }
    final includes = entry['include'];
    if (includes is List) {
      for (final include in includes) {
        if (include is Map && include['target'] is String) {
          collect(include['target'] as String);
        }
      }
    }
  }

  if (json.containsKey(platform)) {
    collect(platform);
  }
  if (platform != 'vm' && json.containsKey('vm')) {
    collect('vm');
  }
  for (final extra in extraLibraries) {
    names.add(
      extra.startsWith('dart:') ? extra.substring('dart:'.length) : extra,
    );
  }
  return names;
}

/// One URI-bearing directive of a source's prologue.
class ScanRef {
  const ScanRef(this.kind, this.uri);

  /// `import`, `export` or `part`.
  final String kind;

  /// The URI. A configurable import gives the alternative it takes for the VM.
  final String uri;

  bool get isPart => kind == 'part';
}

/// The URI-bearing directives of a source's prologue.
class ScanResult {
  const ScanResult(this.refs);

  final List<ScanRef> refs;
}

/// The directives in the prologue of a Dart source, or null when the prologue has a
/// form this scanner does not read.
ScanResult? scanDirectives(String source, Set<String> vmLibraries) {
  try {
    return _Prologue(_Lexer(source), vmLibraries).parse();
  } on _Unparsable {
    return null;
  }
}

class _Unparsable implements Exception {
  const _Unparsable();
}

const _identKind = 0;
const _stringKind = 1;
const _punctKind = 2;
const _otherKind = 3;

class _Token {
  const _Token(this.kind, this.text);

  final int kind;
  final String text;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c == 0x24 ||
    c >= 0x80;

bool _isIdentChar(int c) => _isIdentStart(c) || _isDigit(c);

/// The index just past the block comment that starts at `start`. Dart block
/// comments nest.
int _skipBlockComment(String src, int start) {
  var depth = 0;
  var at = start;
  while (at < src.length) {
    if (src.startsWith('/*', at)) {
      depth++;
      at += 2;
    } else if (src.startsWith('*/', at)) {
      depth--;
      at += 2;
      if (depth == 0) return at;
    } else {
      at++;
    }
  }
  return src.length;
}

/// Reads the tokens of a Dart source one at a time, so a scan that stops at the end
/// of the directives never reads the rest of the file.
class _Lexer {
  _Lexer(this._src);

  final String _src;
  var _at = 0;
  _Token? _ahead;

  _Token? peek() => _ahead ??= _scan();

  _Token? take() {
    final token = peek();
    _ahead = null;
    return token;
  }

  _Token? _scan() {
    final src = _src;
    final n = src.length;
    if (_at == 0) {
      if (src.startsWith('\uFEFF')) _at++;
      if (src.startsWith('#!', _at)) {
        final end = src.indexOf('\n', _at);
        _at = end < 0 ? n : end;
      }
    }
    while (_at < n) {
      final ch = src[_at];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        _at++;
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '/') {
        final end = src.indexOf('\n', _at);
        _at = end < 0 ? n : end;
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '*') {
        _at = _skipBlockComment(src, _at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        final word = src.substring(start, _at);
        if (word == 'r' && _at < n && (src[_at] == "'" || src[_at] == '"')) {
          return _string(raw: true);
        }
        return _Token(_identKind, word);
      }
      if (_isDigit(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        return _Token(_otherKind, src.substring(start, _at));
      }
      if (ch == "'" || ch == '"') return _string(raw: false);
      _at++;
      return _Token(_punctKind, ch);
    }
    return null;
  }

  /// The string literal at `_at`, with its quotes removed and its escapes kept.
  _Token _string({required bool raw}) {
    final src = _src;
    final n = src.length;
    final quote = src[_at];
    final triple = src.startsWith(quote * 3, _at);
    final delim = triple ? quote * 3 : quote;
    final start = _at + delim.length;
    var at = start;
    while (true) {
      if (at >= n) throw const _Unparsable();
      if (!raw && src[at] == '\\') {
        at += 2;
        continue;
      }
      if (src.startsWith(delim, at)) break;
      if (!triple && src[at] == '\n') throw const _Unparsable();
      at++;
    }
    _at = at + delim.length;
    return _Token(_stringKind, src.substring(start, at));
  }
}

/// Reads the directive prologue: `library`, `import`, `export`, `part` and `part
/// of`, with the annotations before them. The first other token ends it.
class _Prologue {
  _Prologue(this._lexer, this._vm);

  final _Lexer _lexer;
  final Set<String> _vm;

  _Token? _peek() => _lexer.peek();

  _Token _take() {
    final token = _lexer.take();
    if (token == null) throw const _Unparsable();
    return token;
  }

  bool _is(String text, int kind) {
    final token = _peek();
    return token != null && token.kind == kind && token.text == text;
  }

  bool _ident(String text) => _is(text, _identKind);

  bool _punct(String text) => _is(text, _punctKind);

  void _expect(String text) {
    if (!_punct(text)) throw const _Unparsable();
    _lexer.take();
  }

  /// Consumes up to and including `text`.
  void _skipPast(String text) {
    while (!_punct(text)) {
      _take();
    }
    _lexer.take();
  }

  void _identToken() {
    if (_take().kind != _identKind) throw const _Unparsable();
  }

  /// Adjacent string literals are one URI.
  String _string() {
    final token = _take();
    if (token.kind != _stringKind) throw const _Unparsable();
    var value = token.text;
    while (_peek()?.kind == _stringKind) {
      value += _take().text;
    }
    return value;
  }

  /// `@name`, `@name.name`, `@name<...>(...)`, or `@name<...>.name(...)`.
  void _annotation() {
    _expect('@');
    _identToken();
    while (_punct('.')) {
      _lexer.take();
      _identToken();
    }
    if (_punct('<')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '<') depth++;
        if (token.kind == _punctKind && token.text == '>') depth--;
      } while (depth > 0);
      while (_punct('.')) {
        _lexer.take();
        _identToken();
      }
    }
    if (_punct('(')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '(') depth++;
        if (token.kind == _punctKind && token.text == ')') depth--;
      } while (depth > 0);
    }
  }

  /// The `if (...)` test of a configurable import, after its `(`, through its `)`.
  /// True when it holds for the VM. Only `dart.library.X`, with no operator or with
  /// `== 'true'`, can hold, and `== 'false'` negates it. Any other name is false.
  bool _condition() {
    final name = StringBuffer();
    String? value;
    while (!_punct(')')) {
      final token = _take();
      if (token.kind == _identKind ||
          (token.kind == _punctKind && token.text == '.')) {
        name.write(token.text);
      } else if (token.kind == _stringKind) {
        value = token.text;
      } else if (!(token.kind == _punctKind && token.text == '=')) {
        throw const _Unparsable();
      }
    }
    _lexer.take();
    const prefix = 'dart.library.';
    final text = name.toString();
    if (!text.startsWith(prefix)) return false;
    final present = _vm.contains(text.substring(prefix.length));
    if (value == null || value == 'true') return present;
    return value == 'false' ? !present : false;
  }

  /// `import` or `export`: the URI, then any `if` alternatives, then the rest of the
  /// directive, which names nothing to read.
  ScanRef _uriDirective(String kind) {
    _lexer.take();
    final declared = _string();
    var chosen = declared;
    var picked = false;
    while (_ident('if')) {
      _lexer.take();
      _expect('(');
      final holds = _condition();
      final alternative = _string();
      if (holds && !picked) {
        chosen = alternative;
        picked = true;
      }
    }
    _skipPast(';');
    return ScanRef(kind, chosen);
  }

  ScanResult parse() {
    final refs = <ScanRef>[];
    while (true) {
      final token = _peek();
      if (token == null) break;
      if (token.kind == _punctKind && token.text == '@') {
        _annotation();
        continue;
      }
      if (token.kind != _identKind) break;
      if (token.text == 'library') {
        _lexer.take();
        _skipPast(';');
      } else if (token.text == 'import' || token.text == 'export') {
        refs.add(_uriDirective(token.text));
      } else if (token.text == 'part') {
        _lexer.take();
        if (_ident('of')) {
          _skipPast(';');
        } else {
          refs.add(ScanRef('part', _string()));
          _expect(';');
        }
      } else {
        break;
      }
    }
    return ScanResult(refs);
  }
}

/// Each package's root, read from the `package_config.json` the module compiles
/// against, so a `package:` source can be matched to the path a diagnostic names.
Future<Map<String, _PackageRoot>> _packageRoots(
  String packagesFile,
  String multiRootPrefix,
) async {
  final config = jsonDecode(await File(packagesFile).readAsString()) as Map;
  final roots = <String, _PackageRoot>{};
  for (final entry in (config['packages'] as List).cast<Map>()) {
    var root = entry['rootUri'] as String;
    if (root.startsWith(multiRootPrefix)) {
      root = root.substring(multiRootPrefix.length);
    }
    if (root.isNotEmpty && !root.endsWith('/')) root = '$root/';
    final packageUri = (entry['packageUri'] as String?) ?? 'lib/';
    roots[entry['name'] as String] = _PackageRoot(root, packageUri);
  }
  return roots;
}

class _PackageRoot {
  const _PackageRoot(this.path, this.packageUri);

  /// The `rootUri` with its scheme removed, ending in `/` unless empty.
  final String path;

  /// The `packageUri`, ending in `/`.
  final String packageUri;
}

/// Expands `@params` arguments in one-shot mode, one argument per line.
Future<List<String>> _expandParamFiles(List<String> args) async {
  final out = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@') && File(arg.substring(1)).existsSync()) {
      final lines = await File(arg.substring(1)).readAsLines();
      out.addAll(lines);
    } else {
      out.add(arg);
    }
  }
  return out;
}

/// The result of one `kernel_worker` run.
class ModuleOutcome {
  const ModuleOutcome(this.exitCode, this.output);

  final int exitCode;
  final String output;
}

/// Runs `kernel_worker` with a full argument list. `inputs` are the Bazel
/// `WorkRequest.inputs` of the request. They are passed on unchanged, so the child
/// receives the request Bazel would have sent it.
abstract class ModuleCompiler {
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs);

  Future<void> close();
}

/// One `kernel_worker` process per compile.
class _OneShot implements ModuleCompiler {
  _OneShot(this._dartaotruntime, this._kernelWorker);

  final String _dartaotruntime;
  final String _kernelWorker;

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final result = await Process.run(_dartaotruntime, [_kernelWorker, ...args]);
    return ModuleOutcome(result.exitCode, '${result.stdout}${result.stderr}');
  }

  @override
  Future<void> close() async {}
}

/// One `kernel_worker` child, kept running across requests.
///
/// A child that cannot be trusted is killed and replaced, and its request is sent
/// once more to the new child. That is after the child dies; after a request that runs
/// past the timeout, which a wedged child does; after bytes that are not the
/// `WorkResponse` to the request; and after a crash, since the child then never answers
/// its next request. A compile writes only its own outputs, so repeating it is safe.
/// A request that fails again on the new child fails the action with both reasons.
class _Persistent implements ModuleCompiler {
  _Persistent(
    this._dartaotruntime,
    this._kernelWorker, {
    Duration? requestTimeout,
  }) : _requestTimeout = requestTimeout ?? _defaultRequestTimeout;

  /// Far above the compile of one library. A request that takes longer is wedged.
  /// `--request-timeout-seconds` replaces it, so a test can exercise a wedged child
  /// without waiting this long.
  static const _defaultRequestTimeout = Duration(minutes: 15);

  /// What the compiler prints for a crash.
  static const _crashMarker = 'Crash when compiling';

  final String _dartaotruntime;
  final String _kernelWorker;
  final Duration _requestTimeout;
  Process? _child;
  _Frames? _responses;

  /// The `request_id` of every request. Bazel sends a worker that is not multiplexed
  /// request 0, and `kernel_worker` answers with the id it was sent.
  static const _requestId = 0;

  /// The child's stderr, kept for the failure message of a child that dies.
  final _stderr = StringBuffer();

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    // Digested before the child is written to, so a file that cannot be read fails the
    // request with its reason, not as a child that died.
    final withDigests = await _withDigests(args, inputs);
    final first = await _attempt(args, withDigests);
    if (!first.lost) return first.outcome;
    final second = await _attempt(args, withDigests);
    if (second.lost) {
      return ModuleOutcome(
        second.outcome.exitCode,
        'Failed twice, on a fresh kernel_worker each time.\n'
        'First attempt: ${first.outcome.output}\nSecond attempt: '
        '${second.outcome.output}',
      );
    }
    return second.outcome;
  }

  /// Sends one request to the running child, or to a new one, and reads its answer.
  Future<_Attempt> _attempt(List<String> args, List<Uint8List> inputs) async {
    final child = await _start();
    try {
      child.stdin.add(_frame(_encodeRequest(args, inputs, _requestId)));
      await child.stdin.flush();
    } on Object {
      // A child that died before reading the request: the read below reports it.
    }
    try {
      final frame = await _responses!.next().timeout(_requestTimeout);
      if (frame == null) {
        await _reap();
        return _Attempt(
          ModuleOutcome(1, 'kernel_worker exited before responding.\n$_stderr'),
          lost: true,
        );
      }
      final response = _WorkResponse.decode(frame);
      if (response.requestId != _requestId) {
        throw FormatException(
          'it answered request ${response.requestId}, not request $_requestId',
        );
      }
      final outcome = ModuleOutcome(response.exitCode, response.output);
      final crashed =
          outcome.exitCode != 0 && outcome.output.contains(_crashMarker);
      if (crashed) await _reap();
      return _Attempt(outcome, lost: crashed);
    } on TimeoutException {
      await _reap();
      return _Attempt(
        ModuleOutcome(
          1,
          'kernel_worker did not answer within $_requestTimeout, so it was '
          'killed.\n$_stderr',
        ),
        lost: true,
      );
    } catch (error) {
      await _reap();
      return _Attempt(
        ModuleOutcome(
          1,
          'kernel_worker sent bytes that are not a WorkResponse ($error), so it was '
          'killed.\n$_stderr',
        ),
        lost: true,
      );
    }
  }

  Future<Process> _start() async {
    final running = _child;
    if (running != null) return running;
    final child = await Process.start(_dartaotruntime, [
      _kernelWorker,
      _persistentFlag,
    ]);
    _stderr.clear();
    child.stderr.transform(utf8.decoder).listen(_stderr.write);
    _child = child;
    _responses = _Frames(child.stdout);
    return child;
  }

  /// Kills the child and waits for it to exit. The kill is SIGKILL: a stopped child
  /// does not act on SIGTERM until it is continued, so waiting after SIGTERM could wait
  /// forever.
  Future<void> _reap() async {
    final child = _child;
    _child = null;
    if (child == null) return;
    child.kill(ProcessSignal.sigkill);
    unawaited(child.stdin.close().catchError((Object _) {}));
    await child.exitCode;
  }

  @override
  Future<void> close() => _reap();
}

/// One attempt at a request. `lost` is set when the child died, wedged, or answered
/// with bytes that are not the answer, or crashed, so the request is repeated.
class _Attempt {
  _Attempt(this.outcome, {required this.lost});

  final ModuleOutcome outcome;
  final bool lost;
}

/// The startup flag that sets the request timeout, in seconds. A test passes it with
/// `--worker_extra_flag=DartKernel=--request-timeout-seconds=N`.
const _requestTimeoutFlag = '--request-timeout-seconds=';

// ---------------------------------------------------------------------------
// Digests. Bazel declares a tree artifact's files as one directory, so it does not
// send their digests in the request, and `kernel_worker` fails a request that reads a
// file it was not sent a digest for. The tool digests such a file itself, with the
// same SHA-256 that Bazel uses for a file, and keeps the digest while the file's size
// and modification time hold: a kernel is hashed once, when it is written.

/// The SHA-256 digest of the file at `path`.
Future<Uint8List> _digestOf(String path) async =>
    sha256Of(await File(path).readAsBytes());

/// The SHA-256 digest of `message`, as 32 bytes.
Uint8List sha256Of(Uint8List message) {
  final h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  // The message, a 0x80 byte, zeros, and its bit length as 64 bits, to a whole block.
  final paddedLength = ((message.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLength)..setRange(0, message.length, message);
  padded[message.length] = 0x80;
  final bits = message.length * 8;
  final view = ByteData.sublistView(padded);
  view.setUint32(paddedLength - 8, bits ~/ 0x100000000);
  view.setUint32(paddedLength - 4, bits & 0xffffffff);

  final w = List<int>.filled(64, 0);
  for (var block = 0; block < paddedLength; block += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(block + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (hh + s1 + ch + _sha256K[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  final out = ByteData(32);
  for (var i = 0; i < 8; i++) {
    out.setUint32(i * 4, h[i]);
  }
  return out.buffer.asUint8List();
}

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

const _sha256K = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// The `Input` message for a file: its `path` and `digest`.
Uint8List _encodeInput(String path, Uint8List digest) {
  final writer = _Writer()
    ..stringField(1, path)
    ..messageField(2, digest);
  return writer.toBytes();
}

/// The `path` of an `Input` message, read without decoding its digest.
String _inputPath(Uint8List bytes) {
  final reader = _Reader(bytes);
  while (!reader.done) {
    final key = reader.varint();
    if (key >> 3 == 1 && key & 7 == 2) return utf8.decode(reader.bytes());
    reader.skip(key & 7);
  }
  return '';
}

/// The request's `inputs`, with a digest added for each `--input-summary` or
/// `--input-linked` file that Bazel did not declare on its own.
Future<List<Uint8List>> _withDigests(
  List<String> args,
  List<Uint8List> inputs,
) async {
  final declared = {for (final input in inputs) _inputPath(input)};
  final out = [...inputs];
  for (var i = 0; i + 1 < args.length; i++) {
    if (args[i] != '--input-summary' && args[i] != '--input-linked') continue;
    final path = args[i + 1];
    if (!declared.add(path)) continue;
    out.add(_encodeInput(path, await _digestOf(path)));
  }
  return out;
}

// ---------------------------------------------------------------------------
// The Bazel worker protocol: varint-length-prefixed protobuf messages. Only the
// fields this tool reads or writes are handled, and the rest are skipped.

/// Reads varint-length-prefixed frames from a byte stream.
class _Frames {
  _Frames(Stream<List<int>> source) : _iterator = StreamIterator(source);

  final StreamIterator<List<int>> _iterator;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;

  Future<bool> _fill() async {
    if (!await _iterator.moveNext()) return false;
    _chunk = Uint8List.fromList(_iterator.current);
    _offset = 0;
    return true;
  }

  Future<int?> _byte() async {
    while (_offset >= _chunk.length) {
      if (!await _fill()) return null;
    }
    return _chunk[_offset++];
  }

  Future<int?> _varint() async {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = await _byte();
      if (byte == null) return null;
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  /// The next frame's bytes, or null at end of stream.
  Future<Uint8List?> next() async {
    final length = await _varint();
    if (length == null) return null;
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      final byte = await _byte();
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }
}

/// Reads one protobuf message.
class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  bool get done => _pos >= _bytes.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = _bytes[_pos++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final length = varint();
    final out = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return out;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        bytes();
      case 5:
        _pos += 4;
      default:
        throw FormatException('Unsupported protobuf wire type $wireType.');
    }
  }
}

/// Writes one protobuf message. Zero values are omitted, as proto3 does.
class _Writer {
  final _out = BytesBuilder();

  void varintField(int field, int value) {
    if (value == 0) return;
    _out.add(_varintBytes(field << 3));
    _out.add(_varintBytes(value));
  }

  void stringField(int field, String value) {
    if (value.isEmpty) return;
    messageField(field, utf8.encode(value));
  }

  /// A length-delimited field: a string, or an embedded message.
  void messageField(int field, List<int> bytes) {
    _out.add(_varintBytes((field << 3) | 2));
    _out.add(_varintBytes(bytes.length));
    _out.add(bytes);
  }

  Uint8List toBytes() => _out.toBytes();
}

Uint8List _varintBytes(int value) {
  final out = BytesBuilder();
  var rest = value;
  while (rest >= 0x80) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest);
  return out.toBytes();
}

Uint8List _frame(Uint8List message) {
  final out = BytesBuilder();
  out.add(_varintBytes(message.length));
  out.add(message);
  return out.toBytes();
}

/// `WorkRequest`: `arguments` = 1, `inputs` = 2 (each an `Input` message, kept as
/// raw bytes so it is forwarded unchanged), `request_id` = 3.
class _WorkRequest {
  _WorkRequest(this.arguments, this.inputs, this.requestId);

  factory _WorkRequest.decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    final arguments = <String>[];
    final inputs = <Uint8List>[];
    var requestId = 0;
    while (!reader.done) {
      final key = reader.varint();
      final field = key >> 3;
      final wire = key & 7;
      if (field == 1 && wire == 2) {
        arguments.add(utf8.decode(reader.bytes()));
      } else if (field == 2 && wire == 2) {
        inputs.add(reader.bytes());
      } else if (field == 3 && wire == 0) {
        requestId = reader.varint();
      } else {
        reader.skip(wire);
      }
    }
    return _WorkRequest(arguments, inputs, requestId);
  }

  final List<String> arguments;
  final List<Uint8List> inputs;
  final int requestId;
}

/// The `WorkRequest` for one compile. The child answers with the same `request_id`.
Uint8List _encodeRequest(
  List<String> arguments,
  List<Uint8List> inputs,
  int requestId,
) {
  final writer = _Writer();
  for (final argument in arguments) {
    writer.stringField(1, argument);
  }
  for (final input in inputs) {
    writer.messageField(2, input);
  }
  writer.varintField(3, requestId);
  return writer.toBytes();
}

/// `WorkResponse`: `exit_code` = 1, `output` = 2, `request_id` = 3.
class _WorkResponse {
  _WorkResponse(this.exitCode, this.output, this.requestId);

  factory _WorkResponse.decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    var exitCode = 0;
    var output = '';
    var requestId = 0;
    while (!reader.done) {
      final key = reader.varint();
      final field = key >> 3;
      final wire = key & 7;
      if (field == 1 && wire == 0) {
        exitCode = reader.varint();
      } else if (field == 2 && wire == 2) {
        output = utf8.decode(reader.bytes());
      } else if (field == 3 && wire == 0) {
        requestId = reader.varint();
      } else {
        reader.skip(wire);
      }
    }
    return _WorkResponse(exitCode, output, requestId);
  }

  final int exitCode;
  final String output;
  final int requestId;
}

Uint8List _encodeResponse(int exitCode, String output, int requestId) {
  final writer = _Writer()
    ..varintField(1, exitCode)
    ..stringField(2, output)
    ..varintField(3, requestId);
  return writer.toBytes();
}

/// Strips `Source.sourceCode` UTF-8 bytes from a compiled Kernel `.dill` while
/// preserving `uri`, `lineStarts`, `importUri`, and `constantCoverageConstructors`.
///
/// `kernel_worker` has no `--no-embed-sources` flag, so it embeds the full source
/// text of every `.dart` file in each module `.dill`'s `SourceTable` (~55% of all
/// `.dill` bytes). The VM uses `lineStarts` (not `sourceCode`) for stack traces and
/// `SourceReport` coverage, and downstream `--input-linked` compiles read only
/// library outlines.
///
/// Format guard: reads the 32-bit kernel format version at byte offset 4 of the
/// header and accepts only [supportedKernelFormatVersions] (version 138, Dart
/// 3.13.x). On any other format version, writes a diagnostic to [errSink]
/// (defaulting to [stderr]) and falls back to returning [data] unstripped,
/// never emitting a malformed `.dill`.
Uint8List stripSourceCodeFromDill(Uint8List data, {StringSink? errSink}) =>
    _stripSourceCodeFromDill(data, errSink: errSink);

Uint8List _stripSourceCodeFromDill(Uint8List data, {StringSink? errSink}) {
  final sink = errSink ?? stderr;
  if (data.length < 8) return data;
  final bd = ByteData.sublistView(data);
  if (bd.getUint32(0) != Tag.ComponentFile) return data;
  final version = bd.getUint32(4);
  if (!supportedKernelFormatVersions.contains(version)) {
    sink.writeln(
      'kernel_module: unsupported kernel format version $version '
      '(supported: $supportedKernelFormatVersions); '
      'falling back to unstripped dill.',
    );
    return data;
  }
  if (data.length < 48) return data;
  final size = bd.getUint32(data.length - 4);
  if (size != data.length) return data;
  final libCount = bd.getUint32(data.length - 8);
  final idxCount = libCount + 12;
  final idxBytes = idxCount * 4;
  if (idxBytes > data.length) return data;
  final rawIdxStart = data.length - idxBytes;

  final fields = List<int>.generate(
    idxCount,
    (i) => bd.getUint32(rawIdxStart + i * 4),
  );
  final offSourceTable = fields[0];
  final offConstantTable = fields[1];
  final offComponentIndex = fields[7];
  if (offSourceTable + 4 > offConstantTable ||
      offConstantTable > offComponentIndex ||
      offComponentIndex > rawIdxStart) {
    return data;
  }

  final numSources = bd.getUint32(offSourceTable);
  if (numSources == 0) return data;

  var pos = offSourceTable + 4;
  int readUInt30() {
    final b0 = data[pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      return ((b0 & 0x3f) << 8) | data[pos++];
    }
    final b1 = data[pos++];
    final b2 = data[pos++];
    final b3 = data[pos++];
    return ((b0 & 0x3f) << 24) | (b1 << 16) | (b2 << 8) | b3;
  }

  final newSt = BytesBuilder(copy: false);
  final header4 = ByteData(4)..setUint32(0, numSources);
  newSt.add(header4.buffer.asUint8List());
  final newSourceOffsets = List<int>.filled(numSources, 0);

  for (var i = 0; i < numSources; i++) {
    newSourceOffsets[i] = offSourceTable + newSt.length;

    // 1. uri: UInt30 byteLength + UTF-8 bytes
    final uStart = pos;
    final uLen = readUInt30();
    pos += uLen;
    newSt.add(Uint8List.sublistView(data, uStart, pos));

    // 2. sourceCode: UInt30 byteLength + UTF-8 bytes -> replace with empty (0x00)
    final sLen = readUInt30();
    pos += sLen;
    newSt.addByte(0);

    // 3. lineStarts: UInt30 count + count * UInt30 delta
    final lsStart = pos;
    final lineCount = readUInt30();
    for (var j = 0; j < lineCount; j++) {
      readUInt30();
    }
    // 4. importUri: UInt30 byteLength + UTF-8 bytes
    final iuLen = readUInt30();
    pos += iuLen;
    // 5. constantCoverageConstructors: UInt30 count + count * UInt30
    final ccCount = readUInt30();
    for (var j = 0; j < ccCount; j++) {
      readUInt30();
    }
    newSt.add(Uint8List.sublistView(data, lsStart, pos));
  }

  final offsetsBuf = ByteData(numSources * 4);
  for (var i = 0; i < numSources; i++) {
    offsetsBuf.setUint32(i * 4, newSourceOffsets[i]);
  }
  newSt.add(offsetsBuf.buffer.asUint8List());

  final newStBytes = newSt.takeBytes();
  final oldStLen = offConstantTable - offSourceTable;
  final delta = newStBytes.length - oldStLen;
  if (delta == 0) return data;

  final out = BytesBuilder(copy: false);
  out.add(Uint8List.sublistView(data, 0, offSourceTable));
  out.add(newStBytes);
  out.add(Uint8List.sublistView(data, offConstantTable, offComponentIndex));

  final newOffComponentIndex = out.length;
  final totalUnpadded = out.length + idxBytes;
  final pad = (8 - (totalUnpadded % 8)) % 8;
  if (pad > 0) {
    out.add(Uint8List(pad));
  }

  for (var i = 1; i <= 6; i++) {
    fields[i] += delta;
  }
  fields[7] = newOffComponentIndex;
  fields[idxCount - 1] = out.length + idxBytes;

  final idxBuf = ByteData(idxBytes);
  for (var i = 0; i < idxCount; i++) {
    idxBuf.setUint32(i * 4, fields[i]);
  }
  out.add(idxBuf.buffer.asUint8List());
  return out.takeBytes();
}
