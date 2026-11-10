import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Collects a `dart_test`'s line coverage under `bazel coverage` and writes it
/// as an LCOV tracefile, which Bazel's coverage runner merges into the test's
/// `coverage.dat`.
///
/// The test launcher runs it in one of two ways:
///
/// * `--service-info=<file> -- <vm command>`: for a plain-`main()` test, this
///   runs the VM, which the command starts with its service on, writing where
///   it listens to `<file>`, and with `--pause-isolates-on-exit`. Once every
///   isolate has paused on exit this collects, writes the tracefile and lets
///   the VM go on, and exits as the VM does. A VM that ends before its isolates
///   pause (a test that calls `exit()`) leaves no coverage to collect, which
///   fails the test.
/// * `--runner-coverage=<dir>`: `package:test`'s runner collected each suite
///   itself (`--coverage=<dir>`); this converts what it wrote.
///
/// Either way `--sources=<file>` (written by `dart_test`) names each package's
/// `lib/` directories, and Bazel's `COVERAGE_MANIFEST` the files the test
/// instruments, by path from the exec root. A script is reported under its
/// path in the manifest, and one that is not there (the SDK's, a generated
/// entrypoint's, a library `--instrumentation_filter` leaves out) is not
/// reported.
Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  final manifest = Platform.environment['COVERAGE_MANIFEST'];
  if (manifest == null) {
    _fail('COVERAGE_MANIFEST is not set; run under `bazel coverage`');
  }
  final sources = CoverageSources(
    instrumented: File(manifest).readAsLinesSync(),
    packages: _readPackages(options.sources),
  );
  if (options.serviceInfo case final info?) {
    exit(await _runVm(options.vm, File(info), sources, options.output));
  }
  final directory = Directory(options.runnerCoverage!);
  final hits = directory.existsSync()
      ? await HitMap.parseFiles(
          directory
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json')),
        )
      : <String, HitMap>{};
  _write(options.output, lcov(hits, sources));
}

/// Runs the VM [command], collects its coverage once it has paused on exit,
/// and returns the VM's exit code.
Future<int> _runVm(
  List<String> command,
  File info,
  CoverageSources sources,
  String output,
) async {
  final vm = await Process.start(
    command.first,
    command.sublist(1),
    mode: ProcessStartMode.inheritStdio,
  );
  var exited = false;
  final vmExit = vm.exitCode.whenComplete(() => exited = true);
  final hits = await _collectOnExit(info, () => exited, vmExit);
  if (hits != null) _write(output, lcov(hits, sources));
  final code = await vmExit;
  if (hits != null) return code;
  stderr.writeln(
    'dart_test: the test ended the VM before its coverage could be '
    'collected. Under `bazel coverage` a plain-main() test must return from '
    'main (setting `exitCode` to fail) rather than call `exit()`.',
  );
  return code == 0 ? 1 : code;
}

/// The coverage of the VM whose service [info] names, once each of its
/// isolates has paused on exit, which it then lets go on; or `null` when the
/// VM [exited] first, which [vmExit] completes on.
Future<Map<String, HitMap>?> _collectOnExit(
  File info,
  bool Function() exited,
  Future<void> vmExit,
) async {
  // A service call fails when the VM goes; its exit may be seen a moment
  // after.
  Future<bool> gone() => vmExit
      .then((_) => true)
      .timeout(const Duration(seconds: 5), onTimeout: () => false);
  final uri = await _serviceUri(info, exited);
  if (uri == null) return null;
  final VmService service;
  try {
    service = await vmServiceConnectUri(_webSocketUri(uri).toString());
  } on Object {
    if (await gone()) return null;
    rethrow;
  }
  try {
    // The program is done once every isolate left has paused as it exits.
    while (!await _allPausedOnExit(service)) {
      if (exited()) return null;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final json = await collect(uri, false, false, false, const {});
    final hits = await HitMap.parseJson(
      (json['coverage'] as List).cast<Map<String, dynamic>>(),
    );
    try {
      for (final ref in (await service.getVM()).isolates ?? <IsolateRef>[]) {
        await service.resume(ref.id!);
      }
    } on Object {
      // Resuming one isolate can end the VM before the next is resumed.
    }
    return hits;
  } on Object {
    if (await gone()) return null;
    rethrow;
  } finally {
    await service.dispose();
  }
}

Future<bool> _allPausedOnExit(VmService service) async {
  final isolates = (await service.getVM()).isolates ?? const <IsolateRef>[];
  if (isolates.isEmpty) return false;
  for (final ref in isolates) {
    try {
      final isolate = await service.getIsolate(ref.id!);
      if (isolate.pauseEvent?.kind != EventKind.kPauseExit) return false;
    } on SentinelException {
      // Gone already.
    }
  }
  return true;
}

/// Writes [content] to [path] whole, under another name first: the coverage
/// runner merges every `*.dat`.
void _write(String path, String content) {
  final partial = File('$path.partial')..writeAsStringSync(content);
  partial.renameSync(path);
}

/// Where each script of a test's program is in the workspace.
class CoverageSources {
  CoverageSources({
    required Iterable<String> instrumented,
    required this.packages,
  }) {
    for (final line in instrumented) {
      final path = line.trim();
      if (path.isEmpty) continue;
      _byRootPath[_rootPath(path)] = path;
    }
  }

  /// Each package's `lib/` directories, by path below the kernel roots.
  final Map<String, List<String>> packages;

  /// Instrumented files by path below the kernel roots: a generated file's
  /// path with its output directory taken off.
  final _byRootPath = <String, String>{};

  static final _outputDirectory = RegExp(r'^bazel-out/[^/]+/bin/');

  static String _rootPath(String execPath) =>
      execPath.replaceFirst(_outputDirectory, '');

  /// The instrumented file [script] (a VM script URI) names, by its path from
  /// the exec root, or `null` when it names none.
  String? pathOf(String script) {
    final uri = Uri.parse(script);
    switch (uri.scheme) {
      case 'org-dartlang-root':
        return _byRootPath[uri.path.substring(1)];
      case 'package':
        final slash = uri.path.indexOf('/');
        if (slash < 0) return null;
        final name = uri.path.substring(0, slash);
        final rest = uri.path.substring(slash + 1);
        for (final lib in packages[name] ?? const <String>[]) {
          if (_byRootPath['$lib$rest'] case final path?) return path;
        }
    }
    return null;
  }
}

/// [hits] as an LCOV tracefile of the scripts [sources] places, in path
/// order, lines ascending.
String lcov(Map<String, HitMap> hits, CoverageSources sources) {
  final byPath = <String, Map<int, int>>{};
  for (final MapEntry(key: script, value: hitMap) in hits.entries) {
    final path = sources.pathOf(script);
    if (path == null) continue;
    final lines = byPath.putIfAbsent(path, () => {});
    for (final MapEntry(key: line, value: count) in hitMap.lineHits.entries) {
      lines[line] = (lines[line] ?? 0) + count;
    }
  }
  final out = StringBuffer();
  for (final path in byPath.keys.toList()..sort()) {
    final lines = byPath[path]!;
    out.writeln('SF:$path');
    for (final line in lines.keys.toList()..sort()) {
      out.writeln('DA:$line,${lines[line]}');
    }
    out
      ..writeln('LH:${lines.values.where((c) => c > 0).length}')
      ..writeln('LF:${lines.length}')
      ..writeln('end_of_record');
  }
  return out.toString();
}

Map<String, List<String>> _readPackages(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map;
  return {
    for (final MapEntry(:key, :value) in (json['packages'] as Map).entries)
      key as String: (value as List).cast<String>(),
  };
}

/// The service URI the VM writes to [info] once its service listens, or
/// `null` if the VM has [exited] first.
Future<Uri?> _serviceUri(File info, bool Function() exited) async {
  while (!exited()) {
    if (info.existsSync()) {
      final text = info.readAsStringSync();
      // Read again until the VM has written it whole.
      try {
        final json = jsonDecode(text) as Map<String, dynamic>;
        return Uri.parse(json['uri'] as String);
      } on FormatException {
        // Not yet.
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return null;
}

Uri _webSocketUri(Uri service) {
  final segments = [...service.pathSegments.where((s) => s.isNotEmpty), 'ws'];
  return service.replace(scheme: 'ws', pathSegments: segments);
}

class _Options {
  _Options(
    this.output,
    this.sources,
    this.serviceInfo,
    this.runnerCoverage,
    this.vm,
  );

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    final separator = args.indexOf('--');
    final own = separator < 0 ? args : args.sublist(0, separator);
    for (final arg in own) {
      final match = RegExp(r'^--([a-z-]+)=(.*)$').firstMatch(arg);
      if (match == null) _fail('unexpected argument $arg');
      values[match[1]!] = match[2]!;
    }
    String required(String name) =>
        values[name] ?? _fail('--$name is required');
    final options = _Options(
      required('output'),
      required('sources'),
      values['service-info'],
      values['runner-coverage'],
      separator < 0 ? const [] : args.sublist(separator + 1),
    );
    if ((options.serviceInfo == null) == (options.runnerCoverage == null)) {
      _fail('give one of --service-info and --runner-coverage');
    }
    if ((options.serviceInfo != null) == options.vm.isEmpty) {
      _fail('--service-info needs the VM command after `--`, and only it');
    }
    return options;
  }

  final String output;
  final String sources;
  final String? serviceInfo;
  final String? runnerCoverage;

  /// The VM command, after `--`.
  final List<String> vm;
}

Never _fail(String message) {
  stderr.writeln('dart_test coverage: $message');
  exit(2);
}
