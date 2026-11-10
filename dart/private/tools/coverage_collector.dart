import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coverage/coverage.dart';
import 'package:runfiles/runfiles.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'coverage_lcov.dart';

/// Collects a plain-`main()` `dart_test`'s line coverage under `bazel coverage`
/// and writes it as an LCOV tracefile, which Bazel's coverage runner merges
/// into the test's `coverage.dat`.
///
/// `--service-info=<file> --sources=<file> --output=<file> -- <vm command>`
/// runs the VM, which the command starts with its service on, writing where it
/// listens to `<file>`, and with `--pause-isolates-on-exit`. Once every isolate
/// has paused on exit this collects, writes the tracefile and lets the VM go
/// on, and exits as the VM does. A VM that ends before its isolates pause (a
/// test that calls `exit()`) leaves no coverage to collect, which fails the
/// test.
///
/// A `package:test` test's runner collects its own suites; `coverage_converter`
/// converts what it wrote. The `--sources` file and `COVERAGE_MANIFEST` are as
/// that tool reads them, and the tracefile is what it writes, without the lines
/// and files the sources mark `coverage:ignore`, read from the runfiles of the
/// test this runs in.
Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  final manifest = Platform.environment['COVERAGE_MANIFEST'];
  if (manifest == null) {
    _fail('COVERAGE_MANIFEST is not set; run under `bazel coverage`');
  }
  final names = readSourcesFile(options.sources);
  final sources = CoverageSources(
    instrumented: File(manifest).readAsLinesSync(),
    packages: names.packages,
    files: names.files,
    locate: Runfiles.create().rlocation,
  );
  exit(
    await _runVm(
      options.vm,
      File(options.serviceInfo),
      sources,
      options.output,
    ),
  );
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
  if (hits != null) writeTracefile(output, lcov(hits, sources));
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
  _Options(this.output, this.sources, this.serviceInfo, this.vm);

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
    final vm = separator < 0 ? const <String>[] : args.sublist(separator + 1);
    if (vm.isEmpty) _fail('the VM command is required after `--`');
    return _Options(
      required('output'),
      required('sources'),
      required('service-info'),
      vm,
    );
  }

  final String output;
  final String sources;
  final String serviceInfo;

  /// The VM command, after `--`.
  final List<String> vm;
}

Never _fail(String message) {
  stderr.writeln('dart_test coverage: $message');
  exit(2);
}
