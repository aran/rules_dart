import 'dart:io';

import 'args.dart';
import 'compile.dart';
import 'declared_view.dart';
import 'manifest.dart';
import 'module_graph.dart';
import 'sources.dart';
import 'uris.dart';

/// `module`: one library target to kernel modules, with `kernel_worker`.
///
/// The target's libraries are split into modules (`module_graph.dart`) and
/// compiled in dependency order, each against the modules it needs alone.
/// Nothing a module does wrong fails the action; the manifest records it, and
/// it matters to whatever reaches that module. A library importing what its
/// target does not depend on is `check`'s to report (`check_command.dart`); here
/// it is a module that does not compile.
///
/// [worker] is a compiler kept from an earlier run, if the caller has one (a
/// Bazel worker); else one is started and stopped here. [digests] are those
/// Bazel gave for the action's inputs. With [declaredInputs], the paths a work
/// request declares, the compiler finds sources only among those
/// (`declared_view.dart`); a sandbox needs no such list. Messages go to [err].
Future<int> runModule(
  Args args, {
  required StringSink err,
  KernelWorker? worker,
  Map<String, List<int>> digests = const {},
  List<String>? declaredInputs,
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
  final supported = supportedLibraries(
    File(args.one('libraries-spec')).readAsStringSync(),
    args.one('libraries-target'),
  );

  final source = readLibraries(
    sources: readSources(args.all('src')),
    roots: roots,
    config: config,
    supported: supported,
  );
  final files = source.files;
  final libraries = source.libraries;

  final planned = planModules(libraries: libraries, supported: supported);
  final manifest = Manifest(
    label: label,
    packages: ownPackages(args),
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
  // The dependencies' kernel files the modules were compiled against, which
  // the outlines refer to.
  final read = <String>{};
  final view = declaredInputs == null
      ? null
      : DeclaredView.stage(
          paths: [configPath, ...args.all('src')],
          declared: declaredInputs,
          roots: roots,
        );
  final compilerRoots = view == null
      ? roots
      : [for (final root in roots) rootArgument(view.of(root))];
  try {
    // Whether the compiler holds state the next module can build on, which
    // only a compile that succeeded leaves. Asked to reuse what a failed
    // compile left, `kernel_worker` can take the next request and never answer.
    var reusable = false;
    for (var i = 0; i < planned.length; i++) {
      final plan = planned[i];
      final record = manifest.modules[i];

      final reach = index.reach(plan.deps);
      if (moduleVerdict(plan, target, reach) case final v?) {
        record
          ..status = v.status
          ..reason = v.reason;
        continue;
      }

      final output = '$outputDir/$i.dill';
      final summaries = [for (final m in reach.order) m.dillPath!];
      read.addAll([
        for (final m in reach.order)
          if (m.manifest != manifest) m.dillPath!,
      ]);
      final sources = [...plan.libraries, ...plan.parts];
      worker ??= KernelWorker(args.one('runtime'), args.one('snapshot'));
      final result = await worker.compile(
        [
          '--target',
          target,
          '--dart-sdk-summary',
          args.one('platform'),
          for (final d in args.all('define')) '-D$d',
          if (args.flag('track-creation-locations'))
            '--track-creation-locations',
          '--multi-root-scheme',
          rootScheme,
          for (final root in compilerRoots) ...['--multi-root', root],
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
          if (reusable) '--reuse-compiler-result',
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
      reusable = result.exitCode == 0 && File(output).existsSync();
      if (reusable) {
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
    view?.delete();
  }

  if (args.optional('outline-tool') case final tool?) {
    final outlined = await _outline(tool, args, manifest, read);
    if (outlined != null) {
      err.writeln('$label: $outlined');
      return 1;
    }
  }
  File(args.one('manifest-output')).writeAsStringSync(manifest.toJson());
  return 0;
}

/// Writes the outline of each of [manifest]'s modules that compiled to
/// `--outline-dir`, under the same name, with `--outline-tool`: what
/// dependents compile against. [read] are the dependencies' kernel files the
/// modules were compiled against. Returns the tool's complaint, if it has one.
Future<String?> _outline(
  String tool,
  Args args,
  Manifest manifest,
  Set<String> read,
) async {
  final outlineDir = args.one('outline-dir');
  Directory(outlineDir).createSync(recursive: true);
  final compiled = [for (final m in manifest.modules) ?m.dill];
  if (compiled.isEmpty) return null;
  // Every dependency's kernel file is named, more than a Windows command line
  // holds for a package with many, so they go in a params file.
  final scratch = Directory.systemTemp.createTempSync('kernel_outline');
  try {
    final params = File('${scratch.path}/params')
      ..writeAsStringSync(
        [
          for (final dill in [args.one('platform'), ...read]) ...[
            '--load',
            dill,
          ],
          for (final dill in compiled) ...[
            '--module',
            '${manifest.dir}/$dill',
            '--outline',
            '$outlineDir/$dill',
          ],
        ].map((line) => '$line\n').join(),
      );
    final result = await Process.run(File(tool).absolute.path, [
      '@${params.path}',
    ]);
    if (result.exitCode == 0) return null;
    return '${result.stdout}${result.stderr}'.trimRight();
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// Whether [plan] is unusable without compiling it, and why: it names a
/// `file:` URI, imports a `dart:` library the platform lacks, or needs a
/// module that is not ok. Null when it can be compiled.
({String status, String reason})? moduleVerdict(
  PlannedModule plan,
  String target,
  ModuleReach reach,
) {
  // The compiler reads a `file:` URI wherever the host has the file, so the
  // module would depend on what the build never declared.
  if (plan.fileUris.isNotEmpty) {
    final one = plan.fileUris.length == 1;
    return (
      status: statusFailed,
      reason:
          'names ${plan.fileUris.join(', ')}, '
          '${one ? 'a file: URI' : 'file: URIs'}, which the compiler would '
          'read from outside the inputs the build declares',
    );
  }
  if (plan.unsupported.isNotEmpty) {
    return (
      status: statusUnsupported,
      reason:
          'is unsupported: ${plan.unsupported.join('; ')}, which the $target '
          'target does not provide',
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
