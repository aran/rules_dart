"""What rules_dart curates for pub packages: code assets and dependency cycles.

**Code assets**, for pub packages that ship a `hook/build.dart`.

A pub package with a build hook produces native libraries that rules_dart
cannot build by running the hook (it is non-hermetic and emits a directory
Bazel cannot predeclare). Where rules_dart provides a Bazel replacement under
`//dart/ext/<package>`, this registry binds it to the package name so that
`pub.from_lock()` attaches it automatically — the user does not name the asset,
and does not have to know that, say, `drift` needs `sqlite3`.

**Dependency cycles**, for pub packages that depend on each other at the
versions pub.dev serves (`dio` and `dio_web_adapter`). Bazel builds no cycle,
so its packages are built as one library, which a build must declare
(`pub.cycle()`). A curated cycle is declared for every build: it applies where
its packages are fetched and form exactly that cycle, and is inert where they
do not (a newer release that dropped the edge, say), so it needs no version
bounds.

**Supported API for other rule sets.** `curated_code_assets()`,
`curated_packages()`, `curated_versions()` and `curated_cycles()` are loadable as `@rules_dart//dart/ext:registry.bzl` and
are covered by this repo's compatibility expectations. rules_flutter calls
them from its own pub-spoke generator, which cannot route through
`pub_lock_package` because Flutter spokes carry plugin metadata and
Apple/Android sub-packages of their own. They return plain strings,
so a caller never handles a registry type, and the labels are fully qualified
(`@rules_dart//…`) so they resolve from a foreign repository.

`_ENTRIES` and `_CYCLES` stay **private** and their shape is free to change —
downstream goes through the functions rather than reading or mirroring the table. It is the
only asset *producer* today; the resolution path in `extensions.bzl` consults
producers in order, which is where a package-shipped manifest or a user overlay
would slot in later.

Entries are version-bounded because an asset id is a path inside a *particular*
version of a package: `//dart/ext/sqlite3` binds
`package:sqlite3/src/ffi/libsqlite3.g.dart`, which is where that package's
bindings live today. Attaching it to a lock pinning a version whose bindings
moved would be silently wrong. `min_version` is inclusive, `max_version`
exclusive; either may be empty for an open bound.
"""

load("//dart/pub:defs.bzl", "parse_semver")

_ENTRIES = {
    "sqlite3": [
        struct(
            min_version = "2.0.0",
            max_version = "",
            labels = ["@rules_dart//dart/ext/sqlite3:code_asset"],
        ),
    ],
    # The native library is built from the 0.6.2 archive itself, whose BoringSSL
    # revision and symbol prefix the Dart bindings name: one version only.
    "webcrypto": [
        struct(
            min_version = "0.6.2",
            max_version = "0.6.3",
            labels = ["@rules_dart//dart/ext/webcrypto:code_asset"],
        ),
    ],
}

def curated_code_assets(package_name, version):
    """Returns curated `dart_code_asset` labels for a locked pub package.

    Args:
      package_name: The pub package name.
      version: The exact version resolved from the lock file.

    Returns:
      List of label strings; empty when rules_dart curates nothing for this
      package at this version.
    """
    entries = _ENTRIES.get(package_name)
    if not entries:
        return []

    parsed = parse_semver(version)
    for entry in entries:
        if entry.min_version and parsed < parse_semver(entry.min_version):
            continue
        if entry.max_version and parsed >= parse_semver(entry.max_version):
            continue
        return list(entry.labels)
    return []

def curated_versions(package_name):
    """Describes the versions of a pub package rules_dart curates assets for.

    For the error a build gives when a package's hook has no replacement, so
    that it names the versions that would get one.

    Args:
      package_name: The pub package name.

    Returns:
      List of pub version constraints, such as `>=0.6.2 <0.6.3`; empty when
      rules_dart curates nothing for this package.
    """
    return [
        " ".join([b for b in [
            ">=" + entry.min_version if entry.min_version else "",
            "<" + entry.max_version if entry.max_version else "",
        ] if b]) or "any"
        for entry in _ENTRIES.get(package_name, [])
    ]

def curated_packages():
    """Returns the pub package names rules_dart curates assets for.

    Used to tell a user which packages have a replacement available when their
    lock pins an unsupported version.

    Returns:
      Sorted list of package names.
    """
    return sorted(_ENTRIES.keys())

# Each a cycle of packages that depend on each other, every package in it.
_CYCLES = [
    # dio's web adapter imports dio, which exports the adapter on the web.
    ["dio", "dio_web_adapter"],
]

def curated_cycles():
    """Returns the dependency cycles rules_dart declares for every build.

    For `dependency_cycle(advisory = ...)` (`@rules_dart//dart/pub:pub_graph.bzl`).

    Returns:
      List of cycles, each the sorted list of its packages.
    """
    return [sorted(c) for c in _CYCLES]
