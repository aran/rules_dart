// What a target's `module` action tells the actions after it: its modules, what
// each holds and needs, and whether each can be used. And the lookups over
// several targets' manifests that `module`, `entry` and `link` all make.
import 'dart:convert';
import 'dart:io';

const statusOk = 'ok';
const statusUnsupported = 'unsupported';
const statusFailed = 'failed';

class ModuleRecord {
  ModuleRecord({
    required this.id,
    required this.libraries,
    required this.parts,
    required this.deps,
    this.dill,
    this.status = statusFailed,
    this.reason,
  });

  factory ModuleRecord.fromJson(Map<String, dynamic> m) => ModuleRecord(
    id: m['id'] as int,
    dill: m['dill'] as String?,
    libraries: (m['libraries'] as List).cast<String>(),
    parts: (m['parts'] as List).cast<String>(),
    deps: (m['deps'] as List).cast<String>(),
    status: m['status'] as String,
    reason: m['reason'] as String?,
  );

  final int id;
  final List<String> libraries;
  final List<String> parts;

  /// Library URIs outside the module that its libraries import or export,
  /// whichever target holds them.
  final List<String> deps;

  /// The kernel file in the target's module directory; null unless [status]
  /// is [statusOk].
  String? dill;
  String status;

  /// For a module that is not ok, one line saying why, then the compiler's
  /// diagnostics if it gave any.
  String? reason;

  bool get isOk => status == statusOk;

  Map<String, Object?> toJson() => {
    'id': id,
    'dill': dill,
    'libraries': libraries,
    'parts': parts,
    'deps': deps,
    'status': status,
    if (reason != null) 'reason': reason,
  };
}

class Manifest {
  Manifest({
    required this.label,
    required this.packages,
    required this.dir,
    required this.modules,
  });

  /// [dir] is where the manifest's kernel files are.
  factory Manifest.read(String dir, String manifestPath) {
    final m = jsonDecode(
      File(manifestPath).readAsStringSync(),
    ) as Map<String, dynamic>;
    return Manifest(
      label: m['label'] as String,
      packages: {
        for (final p
            in ((m['packages'] as List?) ?? const [])
                .cast<Map<String, dynamic>>())
          p['name'] as String: p['package_root'] as String,
      },
      dir: dir,
      modules: [
        for (final module
            in (m['modules'] as List).cast<Map<String, dynamic>>())
          ModuleRecord.fromJson(module),
      ],
    );
  }

  final String label;

  /// The packages the target's own files belong to, by name, each with its
  /// `package_root`: one for a library, none for an executable stating none,
  /// several for packages that depend on each other.
  final Map<String, String> packages;
  final String dir;
  final List<ModuleRecord> modules;

  String toJson() => const JsonEncoder.withIndent('  ').convert({
    'label': label,
    'packages': [
      for (final e in packages.entries)
        {'name': e.key, 'package_root': e.value},
    ],
    'modules': modules,
  });
}

/// One module of one manifest.
class ModuleRef {
  ModuleRef(this.manifest, this.module);

  final Manifest manifest;
  final ModuleRecord module;

  String? get dillPath =>
      module.dill == null ? null : '${manifest.dir}/${module.dill}';

  /// Where the module stands in a message: its first library, and its target.
  String get described => '${module.libraries.first} (${manifest.label})';
}

/// Modules reached from some libraries.
class ModuleReach {
  ModuleReach(this.order, this.discovered, this.via);

  /// Each module after the modules it depends on.
  final List<ModuleRef> order;

  /// Each module in the order the walk first met it.
  final List<ModuleRef> discovered;

  /// The library each module was first reached through.
  final Map<ModuleRef, String> via;
}

/// Which module holds each library, across manifests given dependencies first.
class ModuleIndex {
  /// A manifest that holds a library an earlier one does is ignored whole if
  /// it is the same package from another `package_root` (a package reaching the
  /// build from two package hubs); the earlier one has everything it has.
  /// For any other overlap the earlier module keeps the library and `link`
  /// refuses the build if both modules are used.
  ///
  /// [own] is the manifest being built: its modules are looked up too, never
  /// ignored.
  ModuleIndex(List<Manifest> manifests, {Manifest? own}) {
    for (final manifest in [...manifests, ?own]) {
      var overlaps = false;
      var allHubCopies = true;
      for (final module in manifest.modules) {
        for (final uri in module.libraries) {
          final held = _byLibrary[uri];
          if (held == null) continue;
          overlaps = true;
          if (!sameHubPackage(held.manifest, manifest)) allHubCopies = false;
        }
      }
      if (manifest != own && overlaps && allHubCopies) continue;
      for (final module in manifest.modules) {
        final ref = ModuleRef(manifest, module);
        for (final uri in module.libraries) {
          _byLibrary.putIfAbsent(uri, () => ref);
        }
      }
    }
  }

  final _byLibrary = <String, ModuleRef>{};

  ModuleRef? moduleOf(String libraryUri) => _byLibrary[libraryUri];

  /// The modules [uris] are in and everything they depend on. A dependency
  /// no manifest holds is skipped: it can only be a branch of a conditional
  /// import the compiler did not take, since the importer compiled.
  ModuleReach reach(Iterable<String> uris) {
    final order = <ModuleRef>[];
    final discovered = <ModuleRef>[];
    final via = <ModuleRef, String>{};
    void visit(ModuleRef ref, String uri) {
      if (via.containsKey(ref)) return;
      via[ref] = uri;
      discovered.add(ref);
      for (final dep in ref.module.deps) {
        if (_byLibrary[dep] case final next?) visit(next, dep);
      }
      order.add(ref);
    }

    for (final uri in uris) {
      if (_byLibrary[uri] case final ref?) visit(ref, uri);
    }
    return ModuleReach(order, discovered, via);
  }
}

/// Whether [a] and [b] hold the same packages from other `package_root`s: one
/// package (or one set of packages that depend on each other) supplied by two
/// package hubs.
bool sameHubPackage(Manifest a, Manifest b) =>
    a.packages.isNotEmpty &&
    a.packages.length == b.packages.length &&
    a.packages.entries.every(
      (e) => b.packages.containsKey(e.key) && b.packages[e.key] != e.value,
    );

class Overlap {
  const Overlap(this.uri, this.first, this.second);
  final String uri;
  final Manifest first;
  final Manifest second;
}

/// Picks of [selected] those that may be linked together so that no library is
/// defined twice. A module that overlaps an earlier one is dropped whole. If
/// it is the same package under another `package_root` that is all; any other
/// overlap is also reported in `conflicts`.
({List<ModuleRef> kept, List<Overlap> conflicts}) uniqueModules(
  List<ModuleRef> selected,
) {
  final owner = <String, ModuleRef>{};
  final kept = <ModuleRef>[];
  final conflicts = <Overlap>[];
  for (final ref in selected) {
    final found = <Overlap>[];
    var hubCopy = true;
    for (final uri in ref.module.libraries) {
      final held = owner[uri];
      if (held == null) continue;
      if (!sameHubPackage(held.manifest, ref.manifest)) hubCopy = false;
      found.add(Overlap(uri, held.manifest, ref.manifest));
    }
    if (found.isNotEmpty) {
      if (!hubCopy) conflicts.addAll(found);
      continue;
    }
    kept.add(ref);
    for (final uri in ref.module.libraries) {
      owner[uri] = ref;
    }
  }
  return (kept: kept, conflicts: conflicts);
}

/// One line per library compiled by two different modules.
List<String> overlapMessages(String label, List<Overlap> conflicts) => [
  for (final o in conflicts)
    '$label: ${o.uri} is compiled into both ${o.first.label} and '
        '${o.second.label}. A library can belong to only one target; remove '
        'it from one of them.',
];
