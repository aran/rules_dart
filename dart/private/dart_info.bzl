"""Construction of `DartInfo` and the `DartPackageInfo` records it carries.

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
target that *contributes packages* — one for a library, several for a library
over packages that depend on each other, which pub allows and Bazel does not,
so they are one target. Each package is a `DartPackageInfo` built by
`DartPackageInfo(...)` from what the rule states. `dart_info_no_package()` is
for a target that deliberately carries none: `flutter_material_icons` ships a
font and no Dart, and provides `DartInfo` only because
`flutter_application(deps = ...)` requires one on every dep. Neither takes a
field list, and the enumeration they share lives in `_merged_dart_info` below,
so a field added to `DartInfo` is a change to this file and nowhere else.
`dart_info()` itself is in `dart_summary.bzl`, because it also declares the
library's analyzer summary, which needs the project staging this file cannot
load; it builds the rest through `dart_info_with_summaries()` here.

The narrow signature is the point for the second one. A target with no package
can have no `srcs`, no `package_root`, and no `code_assets` — assets ride
`DartPackageInfo`, which it does not have — so leaving them out makes the
degeneracy structural rather than a convention a caller has to honour.

`DartPackageInfo` — the record `transitive_packages` carries — has a second
construction shape that needed the same treatment: *derivation*.
`colocate_packages` rewrites a package's `package_root` to its assembled directory
and `merge_package_records` unions two records' code assets; each builds a
record from an existing one. Hand-written, those sites re-list the fields they
carry, and a field one of them forgets is dropped from *that record only* — so
the loss is conditional on which build shape reached which site (a package that
happened to need source assembly loses it, a pure-source package keeps it),
which is worse to diagnose than losing it everywhere. `derived_package_info()`
carries every field through and overrides only what is named.

`DartAnalyzableInfo` is built here for the same reason rather than beside the
rules that provide it: it is a `DartInfo` plus the sources that belong to no
package's `lib/`, and the tempting alternative — a provider with its own
`transitive_*` fields — is precisely the second enumeration point everything
above exists to prevent. Its two constructors therefore mirror the two above and
nest the `DartInfo` each builds, instead of restating any part of it:
`dart_analyzable_info()` takes `dart_info()`'s package arguments and nests the
`DartInfo` they make, for a target whose sources *are* packages — the shape a
downstream `flutter_test` has, and the one that made hand-building the outer
provider look like the only option — and `dart_analyzable_info_no_package()` takes
`dart_info_no_package()`'s and nests that, for an entrypoint that contributes
nothing.

So construction goes through here and reading does not: `DartInfo` stays public
and is indexed directly by every consumer. The one deliberate exception is
`//dart/tests/no_lv_fixture`, which hand-builds a `DartInfo` precisely to prove
that analysis refuses one `dart_info()` did not build.

`language_version` is the one parameter `DartPackageInfo(...)` requires rather
than defaults, which is a deliberate exception to the paragraph above: adding a field
here is supposed to reach every call site *without* touching them, and this one
obliges every caller to state it. The reason is that its empty value is not
inert. An absent `languageVersion` in a generated `package_config.json` does not
mean "no language version" — the SDK reads it as the *current* one, so a caller
that simply forgot the argument silently compiles that package under newer
syntax and semantics than its own pubspec allows. Defaulting made "I forgot" and
"this package states none" the same call, and the two have different
consequences. The other optional parameters do not share that shape: the
collections mean "none of these", `version`'s empty is a supported state
`package_agreement_error` reads as "knows less", and `unreplaced_hook` is
derived at repository generation rather than stated by a developer. Requiring the
argument narrows how the constructors may be *called*, not what a package may
say: `language_version = ""` remains legal and keeps its meaning, which
`dart_info_fixture`'s `empty_language_version_test` pins.
"""

load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("//dart/private:package_info.bzl", "check_package_name", "raw_dart_package_info")

visibility("//dart/...")

def package_lib_prefix(package_root):
    """Returns the short_path prefix under which a package's importable files live.

    A Dart package resolves `package:<name>/x.dart` against `<package_root>/lib/`,
    so that — not `package_root` itself — is the prefix that answers "does this file
    belong to the package?" and "what is this file's package-relative path?".
    The root package (empty `package_root`) is the same rule with an empty left half,
    which is the whole reason to write it once: open-coded, the conditional is
    easy to drop, and dropping it silently widens the prefix to the package's
    entire directory — `test/`, `tool/` and `bin/` included.

    Lives here, next to the `DartPackageInfo` that defines `package_root`, because
    this file loads only `//dart:providers.bzl` while `source_set.bzl`,
    `common.bzl` and `dart_library.bzl` — the three consumers — already load it.
    Any other home would introduce a load cycle or a new edge.

    Args:
      package_root: A `DartPackageInfo.package_root` — the package root's short_path,
        empty for the root workspace package.

    Returns:
      The trailing-slashed prefix, e.g. `"pkgs/sub/lib/"` or `"lib/"`.
    """
    return (package_root + "/lib/") if package_root else "lib/"

def dart_info_with_summaries(
        label,
        packages,
        deps,
        srcs,
        resources,
        indirect_deps,
        summaries,
        runfiles = None,
        analysis_deps = []):
    """`dart_info()` (`dart_summary.bzl`) once the library's summaries are known.

    `dart_info()` declares the summary action, which needs the staging this
    file must not load; everything else it does is here.

    Args:
      label: The constructing rule's label, for error messages.
      packages: As `dart_info()`'s.
      deps: As `dart_info()`'s.
      srcs: As `dart_info()`'s.
      resources: As `dart_info()`'s.
      indirect_deps: As `dart_info()`'s.
      summaries: The value of `DartInfo.summaries`, from `summaries_info()`.
      runfiles: This target's own runfiles (its `data`), or None.
      analysis_deps: As `dart_info()`'s.

    Returns:
      A `DartInfo`.
    """
    if not packages:
        fail(("%s: `packages` is empty. A target that contributes no package " +
              "is what `dart_info_no_package()` is for.") % label)

    dep_infos = [dep[DartInfo] for dep in deps]
    if indirect_deps:
        # `getattr`: a dependency built before `deps` existed names none.
        deps_of_deps = {dep_label: None for info in dep_infos for dep_label in getattr(info, "deps", [])}
        for wanted in indirect_deps:
            if wanted not in deps_of_deps:
                fail(("%s: `indirect_deps` names %s, which none of its dependencies " +
                      "depends on directly.") % (label, wanted))

    return _merged_dart_info(
        dep_infos = dep_infos,
        dep_packages = _dep_packages(deps),
        indirect_deps = indirect_deps,
        srcs = srcs,
        resources = resources,
        packages = packages,
        summaries = summaries,
        runfiles = runfiles,
        analysis_infos = [dep[DartInfo] for dep in analysis_deps],
    )

def analysis_only_closure(infos):
    """The packages and files the analyzer reads of `infos` beyond their compile closure, merged.

    Args:
      infos: `DartInfo`s.

    Returns:
      `struct(packages, srcs, resources)` of depsets, as `DartInfo.analysis_only`.
    """

    # `getattr`: a `DartInfo` built by hand names no analysis-only dependency.
    only = [i.analysis_only for i in infos if getattr(i, "analysis_only", None) != None]
    return struct(
        packages = depset(transitive = [o.packages for o in only]),
        srcs = depset(transitive = [o.srcs for o in only]),
        resources = depset(transitive = [o.resources for o in only]),
    )

def analyzed_closure(infos):
    """Everything the analyzer reads of `infos` from source: their compile closure and what only it reads.

    What the `dart_analyze` aspect stages for a target analyzed from source,
    and what a codegen action stages of its `deps`, so the two resolve a
    library alike: `dart:ui` through a `sky_engine` that a `flutter_library`
    below names in `analysis_deps` and nothing compiles.

    Args:
      infos: `DartInfo`s.

    Returns:
      `struct(packages, srcs, resources)` of depsets.
    """
    only = analysis_only_closure(infos)
    return struct(
        packages = depset(transitive = [i.transitive_packages for i in infos] + [only.packages]),
        srcs = depset(transitive = [i.transitive_srcs for i in infos] + [only.srcs]),
        resources = depset(transitive = [i.transitive_resources for i in infos] + [only.resources]),
    )

def dep_summaries(label, deps):
    """The summaries `deps` hand on, merged: what a target's own files are read against.

    Two dependencies whose SDK summaries differ (two `sky_engine`s, or one in
    two configurations) leave an error, since an analysis reads one SDK; one
    reached by several routes is one File and merges.

    Args:
      label: The target's label, for the error, or None for one that has
        none to give (`dart_info_no_package()`).
      deps: Targets providing `DartInfo`.

    Returns:
      `struct(transitive, sdk, sdk_owner, error)`, as `DartInfo.summaries`
      has them.
    """
    transitive = []
    sdk = None
    sdk_owner = None
    error = None
    who = "%s: " % label if label != None else ""
    for dep in deps:
        summaries = getattr(dep[DartInfo], "summaries", None)
        if summaries == None:
            error = error or (
                ("%sdepends on %s, whose `DartInfo` was not built by `dart_info()` and carries no " +
                 "analyzer summaries, which analysis against summaries " +
                 "(`--@rules_dart//dart:analysis_summaries`, on by default) reads. Build it with " +
                 "`dart_info()` from `@rules_dart//dart:utils.bzl`, or build with " +
                 "`--@rules_dart//dart:analysis_summaries=false`.") % (who, dep.label)
            )
            continue
        error = error or summaries.error
        transitive.append(summaries.transitive)
        if summaries.sdk == None:
            continue
        if sdk == None:
            sdk = summaries.sdk
            sdk_owner = summaries.sdk_owner
        elif summaries.sdk != sdk and error == None:
            error = (
                ("%sreaches %s, each of which adds libraries to the Dart SDK with an " +
                 "`_embedder.yaml`; analysis against summaries reads one SDK. Build with " +
                 "`--@rules_dart//dart:analysis_summaries=false` to analyze from source.") %
                (who, (
                    "%s in two configurations (%s and %s)" % (sdk_owner, sdk.root.path, summaries.sdk.root.path)
                ) if sdk_owner == summaries.sdk_owner else "%s and %s" % (sdk_owner, summaries.sdk_owner))
            )
    return struct(
        transitive = depset(transitive = transitive),
        sdk = sdk,
        sdk_owner = sdk_owner,
        error = error,
    )

def summaries_info(merged, summary = None, sdk_summary = None, sdk_owner = None, error = None):
    """`DartInfo.summaries` over the merged `dep_summaries()` and what the target adds.

    Args:
      merged: `dep_summaries()` of the target's dependencies.
      summary: The target's own summary File, or None.
      sdk_summary: The SDK summary the target's own `_embedder.yaml` makes, or None.
      sdk_owner: The target, when it makes `sdk_summary`.
      error: Why the target has no summary, or None.

    Returns:
      A struct with `DartInfo.summaries`' fields.
    """
    return struct(
        transitive = depset([summary], transitive = [merged.transitive]) if summary != None else merged.transitive,
        deps = merged.transitive,
        sdk = sdk_summary or merged.sdk,
        sdk_owner = sdk_owner if sdk_summary != None else merged.sdk_owner,
        error = error or merged.error,
    )

def package_info_from_metadata(label, metadata, package_root):
    """Builds the `DartPackageInfo` of a target that names a `dart_package_metadata`.

    Every fact comes from the declaration, so every record of the package
    carries all of them, whichever of its targets a program reaches. The record
    names the declaration, which is how records of one package are checked to
    name the same one.

    Args:
      label: The constructing rule's label, recorded as the record's `label`.
      metadata: The `DartPackageMetadataInfo` the target names.
      package_root: Where the package's sources are: `metadata.package_root`
        for a target of the package itself, or another directory for a rule
        that assembles the package elsewhere (a `copy_to_directory`).

    Returns:
      A `DartPackageInfo`.
    """
    check_package_name(label, metadata.package_name)
    return raw_dart_package_info(
        label = label,
        package_name = metadata.package_name,
        package_root = package_root,
        version = metadata.version,
        language_version = metadata.language_version,
        code_assets = metadata.code_assets,
        data_assets = metadata.data_assets,
        unreplaced_hook = metadata.unreplaced_hook,
        link_hook = metadata.link_hook,
        link_hook_assets = metadata.link_hook_assets,
        linked_code_assets = metadata.linked_code_assets,
        license_file = metadata.license_file,
        metadata = metadata.label,
    )

def _dep_packages(deps):
    return {
        dep.label: tuple([p.package_name for p in dep[DartInfo].packages])
        for dep in deps
    }

def dart_info_no_package(deps = []):
    """Builds a `DartInfo` for a target that contributes no Dart package.

    For a target that has to be listed in a `deps` attribute requiring
    `DartInfo` but ships no Dart: `flutter_material_icons` provides a font, and
    wants the provider present, not contributing. It records no
    `DartPackageInfo`, so nothing it is listed on gains a `package_config.json`
    entry or a source to compile.

    There is deliberately no `package_name`, `package_root`, `srcs`, `resources` or
    `code_assets` here: its `DartInfo.packages` is empty. Code assets are owned
    by a `DartPackageInfo`, which this target does not have.

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
        dep_packages = _dep_packages(deps),
        indirect_deps = [],
        srcs = [],
        resources = [],
        packages = [],
        # The label is for an error, and a dependency names itself in it.
        summaries = summaries_info(dep_summaries(None, deps)),
    )

def dart_analyzable_info(
        label,
        packages,
        deps = [],
        srcs = [],
        resources = [],
        entry_srcs = []):
    """Builds a `DartAnalyzableInfo` for an executable that contributes packages.

    The executable's counterpart of `dart_info()`, taking its `packages`,
    `deps`, `srcs` and `resources` with the same meanings (and the rule's
    `label` in place of its `ctx`: its own files are analyzed from source, so
    it declares no summary), and the one place `DartAnalyzableInfo` is built
    for a target whose sources *are* packages. A downstream `flutter_test` is
    one shape: it names its package's declaration and its sources are that
    package's `lib/` files, which import each other by `package:` URI. A
    library whose analysis closure differs from its compile closure is
    another: `flutter_library` adds `sky_engine` for the analyzer alone, and a
    Flutter pub library over a dependency cycle does that for several packages
    at once. Without a package record those imports have no package to resolve
    against and every one of them reports `uri_does_not_exist`; the analyzer
    is right, because nothing in a package-less closure names the package
    they ask for.

    The nested `DartInfo` is built as `dart_info()` builds one and the wrapper
    enumerates no field of it, which is what keeps a rule in this position
    from writing `DartAnalyzableInfo(dart_info = dart_info(...))` by hand — a
    second construction site for the outer provider, and precisely what this
    file exists to prevent.

    `srcs` and `entry_srcs` are told apart by `package:` reachability: a file
    under a package's `lib/` is reachable as `package:<package_name>/…` and
    belongs in `srcs`; a file outside every `lib/` (a `test/` entrypoint, a
    `bin/` main) belongs in `entry_srcs`, which no `DartPackageInfo` can name.
    Staging places both by `short_path`, so analysis would resolve either way
    and a `lib/` file in `entry_srcs` would only be invisible to every
    `DartInfo` consumer. So that is refused: an `entry_srcs` file under one of
    this target's own packages' `lib/` fails the build, naming the file.

    Args:
      label: The constructing rule's label, for error messages.
      packages: The `DartPackageInfo` records this target contributes, each
        from `executable_package_record()` or `DartPackageInfo(...)`. At least
        one: an executable contributing no package is what
        `dart_analyzable_info_no_package()` is for.
      deps: Targets providing `DartInfo` whose closures are merged in.
      srcs: This target's own Dart sources that are its packages' `lib/` files,
        exactly as `dart_info(srcs)`.
      resources: This target's own non-Dart files under its packages' `lib/`.
      entry_srcs: The target's own entrypoint sources, outside every package's
        `lib/`. Pass the rule's own `File`s, before any colocation copy:
        consumers stage by `short_path`, and a colocated copy's is the
        assembled directory's.

    Returns:
      A `DartAnalyzableInfo` whose nested `DartInfo` records these packages.
    """

    # Its own files are analyzed from source, never imported: no summary of
    # its own.
    info = dart_info_with_summaries(
        label = label,
        packages = packages,
        deps = deps,
        srcs = srcs,
        resources = resources,
        indirect_deps = [],
        summaries = summaries_info(dep_summaries(label, deps)),
    )
    for f in entry_srcs:
        for p in packages:
            if f.short_path.startswith(package_lib_prefix(p.package_root)):
                fail(("%s: `entry_srcs` file `%s` is under the `lib/` of package " +
                      "`%s`, so `package:%s/…` reaches it. A package's own `lib/` " +
                      "files belong in `srcs`; `entry_srcs` is for files outside " +
                      "every `lib/`.") % (label, f.short_path, p.package_name, p.package_name))
    return DartAnalyzableInfo(
        dart_info = info,
        entry_srcs = depset(entry_srcs),
    )

def dart_analyzable_info_no_package(deps = [], entry_srcs = []):
    """Builds a `DartAnalyzableInfo` for an executable that contributes no package.

    The executable's counterpart of `dart_info_no_package()`. It adds no depset
    of its own beyond `entry_srcs`: the closure is the `DartInfo` that
    `dart_info_no_package()` already knows how to merge, carried whole rather
    than re-enumerated field by field — which is the mistake this file exists to
    prevent, and which a provider with its own `transitive_*` fields would
    reintroduce one merge at a time.

    `entry_srcs` is the one thing that `DartInfo` genuinely cannot carry. An
    entrypoint contributes no package (under pub it belongs to the root package
    but lives outside its `lib/`), so no `DartPackageInfo` can name it and no
    `package:` URI reaches it — but the analyzer still has to see it.

    Args:
      deps: Targets providing `DartInfo` whose closures the entrypoint reaches.
      entry_srcs: The target's own entrypoint sources (its `main` and `srcs`).
        Pass the rule's own `File`s, before any colocation copy: consumers stage
        by `short_path`, and a colocated copy's is the assembled directory's.

    Returns:
      A `DartAnalyzableInfo`.
    """
    return DartAnalyzableInfo(
        dart_info = dart_info_no_package(deps = deps),
        entry_srcs = depset(entry_srcs),
    )

def derived_package_info(
        pkg,
        package_root = None,
        version = None,
        language_version = None,
        code_assets = None,
        data_assets = None,
        unreplaced_hook = None,
        link_hook = None,
        link_hook_assets = None,
        linked_code_assets = None,
        license_file = None):
    """Copies `pkg`, overriding the named fields and carrying the rest through.

    Deriving one package record from another — `colocate_packages` rewriting
    `package_root` to an assembled directory, `merge_package_records` unioning two
    records' assets — is a copy, not a construction, and the caller has an
    opinion about one or two fields at most. Passing the rest through by
    default means a field added to `DartPackageInfo` reaches every derived
    record without those sites being touched, and means neither of them can be
    the one that quietly drops it.

    Args:
      pkg: The `DartPackageInfo` to copy.
      package_root: Replacement `package_root`, or `None` to keep `pkg`'s.
      version: Replacement `version` string (`""` for unknown), or `None` to
        keep `pkg`'s.
      language_version: Replacement `language_version` string (`""` for none
        stated), or `None` to keep `pkg`'s.
      code_assets: Replacement `code_assets` tuple, or `None` to keep `pkg`'s.
      data_assets: Replacement `data_assets` tuple, or `None` to keep `pkg`'s.
      unreplaced_hook: Replacement `unreplaced_hook` string (`""` for
        none), or `None` to keep `pkg`'s.
      link_hook: Replacement `link_hook` File, or `None` to keep `pkg`'s.
      link_hook_assets: Replacement `link_hook_assets` tuple, or `None` to
        keep `pkg`'s.
      linked_code_assets: Replacement `linked_code_assets` tuple, or `None`
        to keep `pkg`'s.
      license_file: Replacement `license_file` File, or `None` to keep `pkg`'s.

    Returns:
      A `DartPackageInfo`.
    """

    # Paired with `package_info_from_metadata()` above: one builds a record from
    # a declaration, this one from an existing record.
    return raw_dart_package_info(
        label = pkg.label,
        package_name = pkg.package_name,
        package_root = pkg.package_root if package_root == None else package_root,
        version = pkg.version if version == None else version,
        language_version = (
            pkg.language_version if language_version == None else language_version
        ),
        code_assets = (
            pkg.code_assets if code_assets == None else code_assets
        ),
        data_assets = (
            pkg.data_assets if data_assets == None else data_assets
        ),
        unreplaced_hook = (
            pkg.unreplaced_hook if unreplaced_hook == None else unreplaced_hook
        ),
        link_hook = pkg.link_hook if link_hook == None else link_hook,
        link_hook_assets = (
            pkg.link_hook_assets if link_hook_assets == None else link_hook_assets
        ),
        linked_code_assets = (
            pkg.linked_code_assets if linked_code_assets == None else linked_code_assets
        ),
        license_file = pkg.license_file if license_file == None else license_file,
        metadata = pkg.metadata,
    )

def _merged_dart_info(
        dep_infos,
        dep_packages,
        indirect_deps,
        srcs,
        resources,
        packages,
        summaries,
        runfiles = None,
        analysis_infos = []):
    """Merges a target's own contributions with its dependencies' closures.

    The single place `DartInfo`'s fields are enumerated. Every public
    constructors route through here, so neither has to be touched when a field
    is added — and neither can be the one that forgets to forward it.

    Args:
      dep_infos: The `DartInfo` of each dependency.
      dep_packages: Each dependency's label and package names, for `DartInfo.deps`.
      indirect_deps: Value for `DartInfo.indirect_deps`.
      srcs: This target's own Dart sources.
      resources: This target's own non-Dart files under `lib/`.
      packages: This target's own `DartPackageInfo` records.
      summaries: Value for `DartInfo.summaries`, from `summaries_info()`.
      runfiles: This target's own runfiles (its `data`), or None.
      analysis_infos: The `DartInfo` of each of the target's `analysis_deps`.

    Returns:
      A `DartInfo`.
    """
    analysis_only = analysis_only_closure(dep_infos + analysis_infos)

    # `getattr`: a provider built before the field existed has none.
    all_runfiles = ([runfiles] if runfiles != None else []) + [
        info.runfiles
        for info in dep_infos
        if getattr(info, "runfiles", None) != None
    ]
    return DartInfo(
        runfiles = all_runfiles[0].merge_all(all_runfiles[1:]) if all_runfiles else None,
        summaries = summaries,
        analysis_only = struct(
            packages = depset(transitive = [i.transitive_packages for i in analysis_infos] + [analysis_only.packages]),
            srcs = depset(transitive = [i.transitive_srcs for i in analysis_infos] + [analysis_only.srcs]),
            resources = depset(transitive = [i.transitive_resources for i in analysis_infos] + [analysis_only.resources]),
        ),
        packages = tuple(packages),
        srcs = list(srcs),
        deps = dict(dep_packages),
        indirect_deps = list(indirect_deps),
        transitive_srcs = depset(
            direct = srcs,
            transitive = [info.transitive_srcs for info in dep_infos],
        ),
        # Beside `transitive_srcs`, never inside it: the two lists are routed to
        # different places. Everything that stages a whole package — the
        # analyzer's project tree, a binary's runfiles — wants both; everything
        # that feeds the compiler wants only the first.
        transitive_src_dirs = depset(
            direct = [f for f in srcs if f.is_directory],
            # `getattr`: a provider built before the field existed has none.
            transitive = [getattr(info, "transitive_src_dirs", depset()) for info in dep_infos],
        ),
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
            direct = [
                a.file
                for pkg in packages
                for a in pkg.code_assets
                if a.file != None
            ],
            transitive = [
                info.transitive_code_asset_files
                for info in dep_infos
                if hasattr(info, "transitive_code_asset_files")
            ],
        ),
    )
