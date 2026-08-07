"""The `DartInfo` constructor.

`DartInfo` is read by everything and built by more than rules_dart: a rule set
that wraps Dart libraries — `flutter_library`, `dart_proto_library` — has to
produce one too. Building it by hand means enumerating every field and merging
every transitive depset one at a time, which made each new field a breaking
change for every such rule set, and made each of them independently work out how
the new field merges.

The worse half of that is not the churn. When a field is missing, the correct
fix (forward the dependencies' values) and the tempting fix (declare it
`depset()` to silence the error) look identical in a diff, and the second one
silently drops every dependency's contribution at that boundary. Handing the
merge to one function makes that mistake unrepresentable rather than merely
warned against.

Two constructors cover every `DartInfo` a build produces. `dart_info()` is for a
target that *contributes a package* — it always records one `DartPackageInfo` of
its own. `dart_info_no_package()` is for one that deliberately carries none:
`flutter_material_icons` ships a font and no Dart, and provides `DartInfo` only
because `flutter_application(deps = ...)` requires one on every dep. Neither
takes a field list, and the enumeration they share lives in `_merged_dart_info`
below, so a field added to `DartInfo` is a change to this file and nowhere else.

The narrow signature is the point for the second one. A target with no package
can have no `srcs`, no `lib_root`, and no `code_assets` — assets ride
`DartPackageInfo`, which it does not have — so leaving them out makes the
degeneracy structural rather than a convention a caller has to honour.

So construction goes through here and reading does not: `DartInfo` stays public
and is indexed directly by every consumer. The one deliberate exception is
`//dart/tests/no_lv_fixture`, which hand-builds a provider missing
`language_version` precisely to prove the tolerance for pre-existing shapes
still holds; a fixture asserting that older producers keep working cannot be
written through a constructor that makes them current.
"""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartPackageInfo")

def check_code_asset_ownership(label, package_name, assets):
    """Checks that every declared asset id is namespaced to this package.

    Upstream requires `CodeAsset.id` to be `package:<package>/<name>` where
    `<package>` is the package that owns the asset — "Code assets are
    name-spaced in their own package to avoid naming conflicts". Since assets
    ride `DartPackageInfo`, an id belonging to some other package would
    propagate under the wrong owner and be impossible to trace back.

    Args:
      label: The owning rule's label (included in the error message).
      package_name: The package name this library declares.
      assets: List of `DartCodeAssetInfo`.

    Returns:
      An error message string on the first mismatch, else `None`.
    """
    prefix = "package:%s/" % package_name
    for asset in assets:
        if not asset.asset_id.startswith(prefix):
            return (
                ("%s: code asset id `%s` is not namespaced to this package. " +
                 "Expected it to start with `%s`, because a code asset is " +
                 "owned by the package declaring it. Either set " +
                 "`package_name = \"…\"` to the owning package, or move the " +
                 "asset to that package's `dart_library`.") %
                (label, asset.asset_id, prefix)
            )
    return None

def dart_info(
        label,
        package_name,
        lib_root,
        deps = [],
        srcs = [],
        resources = [],
        code_assets = [],
        language_version = "",
        has_unreplaced_hook = ""):
    """Builds a `DartInfo` for a library, merging its dependencies' closures.

    The caller supplies only what this target contributes itself; everything
    transitive is merged here. Adding a field to `DartInfo` is therefore a
    change to this file and nothing else.

    Attribute hygiene stays with the calling rule — whether `srcs` and
    `srcs_dir` are mutually exclusive, whether a file sits under the package's
    `lib/` — because those are statements about that rule's attributes, and a
    rule generating its package as one tree artifact has no such files to check.
    What belongs here is what is true of any `DartInfo`: the merges, the package
    record, and code-asset ownership.

    Args:
      label: The constructing rule's label, for error messages.
      package_name: The Dart package name this target provides.
      lib_root: `short_path`-based path to the package root (parent of `lib/`).
        Empty string for the root package.
      deps: Targets providing `DartInfo` whose closures are merged in.
      srcs: This target's own Dart sources (or its source directory).
      resources: This target's own non-Dart files under `lib/`.
      code_assets: Targets providing `DartCodeAssetInfo` that this package owns.
      language_version: Dart language version in `<major>.<minor>` form, or "".
      has_unreplaced_hook: Path of a pub build hook with no Bazel replacement,
        or "".

    Returns:
      A `DartInfo`.
    """
    own_assets = [dep[DartCodeAssetInfo] for dep in code_assets]
    err = check_code_asset_ownership(label, package_name, own_assets)
    if err != None:
        fail(err)

    dep_infos = [dep[DartInfo] for dep in deps]

    this_pkg = DartPackageInfo(
        package_name = package_name,
        lib_root = lib_root,
        language_version = language_version,
        code_assets = tuple(own_assets),
        has_unreplaced_hook = has_unreplaced_hook,
    )

    return _merged_dart_info(
        dep_infos = dep_infos,
        package_name = package_name,
        lib_root = lib_root,
        srcs = srcs,
        resources = resources,
        packages = [this_pkg],
        code_asset_files = [
            a.dynamic_library
            for a in own_assets
            if a.dynamic_library != None
        ],
    )

def dart_info_no_package(deps = []):
    """Builds a `DartInfo` for a target that contributes no Dart package.

    For a target that has to be listed in a `deps` attribute requiring
    `DartInfo` but ships no Dart: `flutter_material_icons` provides a font, and
    wants the provider present, not contributing. It records no
    `DartPackageInfo`, so nothing it is listed on gains a `package_config.json`
    entry or a source to compile.

    There is deliberately no `package_name`, `lib_root`, `srcs`, `resources` or
    `code_assets` here. `DartInfo.package_name` and `.lib_root` describe the
    package a target contributes, and no consumer reads them off the provider —
    package identity is read from `transitive_packages` — so a no-package target
    reports the empty string for both rather than inventing a name with no
    record behind it. Code assets are owned by a `DartPackageInfo`, which this
    target does not have.

    `deps` exists because a facade that groups other libraries is still a
    coherent no-package target, and forwarding their closures is then the whole
    job.

    Args:
      deps: Targets providing `DartInfo` whose closures are merged in.

    Returns:
      A `DartInfo` carrying its dependencies' closures and nothing else.
    """
    return _merged_dart_info(
        dep_infos = [dep[DartInfo] for dep in deps],
        package_name = "",
        lib_root = "",
        srcs = [],
        resources = [],
        packages = [],
        code_asset_files = [],
    )

def _merged_dart_info(
        dep_infos,
        package_name,
        lib_root,
        srcs,
        resources,
        packages,
        code_asset_files):
    """Merges a target's own contributions with its dependencies' closures.

    The single place `DartInfo`'s fields are enumerated. Both public
    constructors route through here, so neither has to be touched when a field
    is added — and neither can be the one that forgets to forward it.

    Args:
      dep_infos: The `DartInfo` of each dependency.
      package_name: Value for `DartInfo.package_name`.
      lib_root: Value for `DartInfo.lib_root`.
      srcs: This target's own Dart sources.
      resources: This target's own non-Dart files under `lib/`.
      packages: This target's own `DartPackageInfo` records (zero or one).
      code_asset_files: This target's own code-asset dynamic libraries.

    Returns:
      A `DartInfo`.
    """
    return DartInfo(
        package_name = package_name,
        lib_root = lib_root,
        transitive_srcs = depset(
            direct = srcs,
            transitive = [info.transitive_srcs for info in dep_infos],
        ),
        # Beside `transitive_srcs`, never inside it: the two lists are routed to
        # different places. Everything that stages a whole package — the
        # analyzer's project tree, a binary's runfiles — wants both; everything
        # that feeds the compiler wants only the first.
        transitive_resources = depset(
            direct = resources,
            transitive = [info.transitive_resources for info in dep_infos],
        ),
        transitive_packages = depset(
            direct = packages,
            transitive = [info.transitive_packages for info in dep_infos],
        ),
        # The libraries travel alongside the package records rather than being
        # recovered from them: a depset of providers cannot be flattened back
        # into `File`s without losing the depset, and runfiles need the files.
        #
        # Alone among the four, this one tolerates a dependency that omits it.
        # That is the documented contract for the field (see
        # `collect_code_asset_files`), and dropping the guard would break
        # providers built before it existed. The other three are read
        # unguarded: a missing one is a dependency that forgot to forward, and
        # failing loudly is the whole point.
        transitive_code_asset_files = depset(
            direct = code_asset_files,
            transitive = [
                info.transitive_code_asset_files
                for info in dep_infos
                if hasattr(info, "transitive_code_asset_files")
            ],
        ),
    )
