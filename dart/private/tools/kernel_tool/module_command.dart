import 'dart:io';

import 'args.dart';
import 'compile.dart';
import 'manifest.dart';
import 'module_graph.dart';
import 'policy.dart';
import 'uris.dart';

/// `module`: one library target to kernel modules, with `kernel_worker`.
///
/// The target's libraries are split into modules (`module_graph.dart`) and
/// compiled in dependency order, each against the modules it needs alone.
/// Nothing a module does wrong fails the action; the manifest records it, and
/// it matters to whatever reaches that module. What fails the action is a
/// target that imports what its BUILD file does not provide (`policy.dart`).
///
/// [worker] is a compiler kept from an earlier run, if the caller has one (a
/// Bazel worker); else one is started and stopped here. [digests] are those
/// Bazel gave for the action's inputs. Messages go to [err].
Future<int> runModule(
  Args args, {
  required StringSink err,
  KernelWorker? worker,
  Map<String, List<int>> digests = const {},
}) async {
  final label = args.one('label');
  final outputDir = args.one('output-dir');
  final target = args.optional('target') ?? 'vm';
  final roots = args.all('multi-root');
  final configPath = args.one('package-config');
  final configRelative = rootRelative(configPath, roots);
  final config = PackageConfig.parse(
    File(configPath).readAsStringSync(),
    configRelative,
  );
  final deps = args.depManifests();
  final depIndex = ModuleIndex(deps);
  final supported = supportedLibraries(
    File(args.one('libraries-spec')).readAsStringSync(),
    args.one('libraries-target'),
  );

  final source = readLibraries(
    sources: _readSources(args.all('src')),
    roots: roots,
    config: config,
    supported: supported,
  );
  final files = source.files;
  final libraries = source.libraries;

  final violations = checkPolicy(
    label: label,
    libraries: libraries,
    partFiles: source.partFiles,
    config: config,
    availablePackages: args.all('available-package').toSet(),
    provided: depIndex.provides,
    ownPackage: args.optional('package-name'),
  );
  final tolerate = args.flag('tolerate-policy');
  if (violations.isNotEmpty && !tolerate) {
    err.writeln(violations.map((v) => v.message).join('\n'));
    return 1;
  }
  final violationsIn = <String, List<String>>{};
  for (final v in violations) {
    (violationsIn[v.library] ??= []).add(
      v.message.startsWith('$label: ')
          ? v.message.substring(label.length + 2)
          : v.message,
    );
  }

  final planned = planModules(libraries: libraries, supported: supported);
  final manifest = Manifest(
    label: label,
    package: args.optional('package-name'),
    libRoot: args.optional('lib-root'),
    dir: outputDir,
    modules: [
      for (var i = 0; i < planned.length; i++)
        ModuleRecord(
          id: i,
          libraries: planned[i].libraries,
          parts: planned[i].parts,
          deps: planned[i].deps,
          status: 'pending',
        ),
    ],
  );
  Directory(outputDir).createSync(recursive: true);

  final index = ModuleIndex(deps, own: manifest);
  final digested = Digests(digests);
  final shared = worker != null;
  try {
    var compiled = 0;
    for (var i = 0; i < planned.length; i++) {
      final plan = planned[i];
      final record = manifest.modules[i];

      final reach = index.reach(plan.deps);
      if (moduleVerdict(plan, target, violationsIn, reach) case final v?) {
        record
          ..status = v.status
          ..reason = v.reason;
        continue;
      }

      final output = '$outputDir/$i.dill';
      final summaries = [for (final m in reach.order) m.dillPath!];
      final sources = [...plan.libraries, ...plan.parts];
      worker ??= KernelWorker(args.one('runtime'), args.one('snapshot'));
      final result = await worker.compile(
        [
          '--target',
          target,
          '--dart-sdk-summary',
          args.one('platform'),
          for (final d in args.all('define')) '-D$d',
          '--multi-root-scheme',
          rootScheme,
          for (final root in roots) ...['--multi-root', root],
          '--packages-file',
          rootUri(configRelative),
          '--no-summary-only',
          '--exclude-non-sources',
          // Without these a persistent worker compiles from scratch each time,
          // no faster than a process per module. The compiler's state is
          // reused only between the modules of one target, never from another
          // target's request: a library can come from a different file there
          // (one package from two pub hubs, a package in another
          // configuration), and a compiler that reused its earlier copy bound
          // this target's classes to stale ones — Flutter widgets that were no
          // longer `Widget`s.
          '--use-incremental-compiler',
          if (compiled > 0) '--reuse-compiler-result',
          for (final summary in summaries) ...['--input-summary', summary],
          for (final uri in sources) ...['--source', uri],
          '--output',
          output,
        ],
        [
          args.one('platform'),
          ...summaries,
          for (final uri in sources) files[uri]!.path,
        ],
        digested,
      );
      compiled++;
      if (result.exitCode == 0 && File(output).existsSync()) {
        record
          ..status = statusOk
          ..dill = '$i.dill';
      } else {
        deleteIfPresent(output);
        record
          ..status = statusFailed
          ..reason = 'does not compile\n${_diagnostics(result.output)}';
      }
    }
  } finally {
    if (!shared) await worker?.close();
  }

  File(args.one('manifest-output')).writeAsStringSync(manifest.toJson());
  return 0;
}

/// Whether [plan] is unusable without compiling it, and why: it imports a
/// `dart:` library the platform lacks, it breaks a dependency rule, or it needs
/// a module that is not ok. Null when it can be compiled.
({String status, String reason})? moduleVerdict(
  PlannedModule plan,
  String target,
  Map<String, List<String>> violationsIn,
  ModuleReach reach,
) {
  if (plan.unsupported.isNotEmpty) {
    return (
      status: statusUnsupported,
      reason:
          'is unsupported: ${plan.unsupported.join('; ')}, which the $target '
          'target does not provide',
    );
  }
  final broken = [for (final uri in plan.libraries) ...?violationsIn[uri]];
  if (broken.isNotEmpty) {
    return (
      status: statusFailed,
      reason: 'breaks a dependency rule:\n${broken.join('\n')}',
    );
  }
  final unusable = reach.order.where((m) => !m.module.isOk).firstOrNull;
  if (unusable == null) return null;
  return (status: statusFailed, reason: _dependsOn(unusable));
}

/// Why a module that needs [unusable] cannot be built: the root cause, however
/// many modules away.
String _dependsOn(ModuleRef unusable) {
  final reason = unusable.module.reason ?? 'cannot be used';
  final split = reason.indexOf('\n');
  final first = split < 0 ? reason : reason.substring(0, split);
  final rest = split < 0 ? '' : reason.substring(split);
  final line = first.startsWith('depends on ')
      ? first
      : 'depends on ${unusable.described}, which $first';
  return '$line$rest';
}

/// The compiler's messages, cut so that a manifest read by every dependent
/// stays small.
String _diagnostics(String output) {
  const maxLines = 60;
  final lines = output.trimRight().split('\n');
  if (lines.length <= maxLines) return lines.join('\n');
  return [
    ...lines.take(maxLines),
    '... ${lines.length - maxLines} more lines',
  ].join('\n');
}

List<SourceFile> _readSources(List<String> srcs) {
  final sources = <SourceFile>[];
  for (final src in srcs) {
    if (Directory(src).existsSync()) {
      final found =
          // Followed: a sandbox stages a tree artifact's files as links.
          Directory(src)
              .listSync(recursive: true, followLinks: true)
              .whereType<File>()
              .map((f) => f.path.replaceAll(r'\', '/'))
              .where((p) => p.endsWith('.dart'))
              .toList()
            ..sort();
      for (final path in found) {
        sources.add(SourceFile(path, File(path).readAsStringSync()));
      }
    } else {
      sources.add(SourceFile(src, File(src).readAsStringSync()));
    }
  }
  return sources;
}
