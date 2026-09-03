"""Tests for the `DartInfo` constructors as rule sets outside rules_dart use them.

`wrapper_library` stands in for `flutter_library` / `dart_proto_library`: a rule
that is not `dart_library`, contributes a package of its own, and reaches
`DartInfo` only through `dart_info()`. The claim under test is that such a
caller gets every dependency's closure without naming any field — which is what
makes a later field addition invisible to it, and makes "declare the field empty
and drop the dependencies' values" impossible to write.

`facade_library` stands in for `flutter_material_icons`: a target that ships no
Dart at all and provides `DartInfo` only because the `deps` attribute it gets
listed in requires one. The claims under test are the same closure forwarding
plus the thing that makes it degenerate — that it adds no package record of its
own, so listing it changes no consumer's `package_config.json`.

`wrapper_executable` stands in for a downstream `flutter_test`: an executable
that also contributes a package, its sources being that package's `lib/` files
plus an entrypoint outside them. The claim under test is the one that made this
shape reach past the public constructors — that the package record really does
reach the nested `DartInfo`, since without it the target's own
`package:<self>/…` imports resolve against nothing — plus the claim that gaining
a package costs it none of the separation: it stays analyzable and stays an
invalid `deps` entry.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartAnalyzableInfo", "DartCodeAssetInfo", "DartInfo")
load("//dart/private:common.bzl", "package_code_assets")
load(
    "//dart/private:dart_info.bzl",
    "dart_analyzable_info_with_package",
    "dart_info",
    "dart_info_no_package",
)

def _wrapper_library_impl(ctx):
    return [
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.resources)),
        dart_info(
            label = ctx.label,
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
            code_assets = ctx.attr.code_assets,
            language_version = ctx.attr.language_version,
        ),
    ]

wrapper_library = rule(
    implementation = _wrapper_library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "resources": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [DartInfo]),
        "code_assets": attr.label_list(providers = [DartCodeAssetInfo]),
        "package_name": attr.string(mandatory = True),
        "language_version": attr.string(),
    },
    doc = "A non-`dart_library` producer of `DartInfo`, built through `dart_info()`.",
)

def _facade_library_impl(ctx):
    return [
        DefaultInfo(files = depset(ctx.files.data)),
        dart_info_no_package(deps = ctx.attr.deps),
    ]

facade_library = rule(
    implementation = _facade_library_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [DartInfo]),
    },
    doc = "A target shipping no Dart package, built through `dart_info_no_package()`.",
)

def _wrapper_executable_impl(ctx):
    return [
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.package_srcs)),
        dart_analyzable_info_with_package(
            label = ctx.label,
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            package_srcs = ctx.files.package_srcs,
            resources = ctx.files.resources,
            code_assets = ctx.attr.code_assets,
            language_version = ctx.attr.language_version,
        ),
    ]

wrapper_executable = rule(
    implementation = _wrapper_executable_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "package_srcs": attr.label_list(allow_files = [".dart"]),
        "resources": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [DartInfo]),
        "code_assets": attr.label_list(providers = [DartCodeAssetInfo]),
        "package_name": attr.string(mandatory = True),
        "language_version": attr.string(),
    },
    doc = "An executable that also contributes a package, built through " +
          "`dart_analyzable_info_with_package()`.",
)

def _short_paths(dep):
    return sorted([f.short_path for f in dep.to_list()])

def _forwards_closures_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartInfo]

    # Sources and resources: the wrapper's own plus every dependency's, and the
    # two kept apart — a resource that leaked into `transitive_srcs` would be
    # handed to the compiler.
    srcs = _short_paths(info.transitive_srcs)
    resources = _short_paths(info.transitive_resources)
    asserts.true(
        env,
        [p for p in srcs if p.endswith("/lib/wrapped.dart")] != [],
        "own source missing from transitive_srcs: %s" % srcs,
    )
    asserts.true(
        env,
        [p for p in srcs if p.endswith("/lib/dep.dart")] != [],
        "dependency's source missing from transitive_srcs: %s" % srcs,
    )
    asserts.true(
        env,
        [p for p in resources if p.endswith("/lib/dep.yaml")] != [],
        "dependency's resource missing from transitive_resources: %s" % resources,
    )
    asserts.true(
        env,
        [p for p in srcs if p.endswith(".yaml")] == [],
        "a resource leaked into transitive_srcs: %s" % srcs,
    )

    # Package records: the wrapper's own and the dependency's.
    names = sorted([p.package_name for p in info.transitive_packages.to_list()])
    asserts.equals(env, ["info_dep", "wrapper_pkg"], names)

    # Code assets, both halves: the id on the dependency's package record, and
    # the library file in the flat depset runfiles are built from.
    ids = []
    for pkg in info.transitive_packages.to_list():
        ids.extend([a.asset_id for a in package_code_assets(pkg)])
    asserts.equals(env, ["package:info_dep/src/ffi/dep.g.dart"], sorted(ids))
    asserts.equals(env, 1, len(info.transitive_code_asset_files.to_list()))

    return analysistest.end(env)

forwards_closures_test = analysistest.make(_forwards_closures_test_impl)

def _no_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartInfo]

    # The degenerate half: no record of its own. A consumer that lists this
    # target gets no extra `package_config.json` entry, which is the reason the
    # provider can be handed out at all.
    names = sorted([p.package_name for p in info.transitive_packages.to_list()])
    asserts.equals(env, ["info_dep"], names)

    # Empty rather than a name with no record behind it. No consumer reads
    # these off `DartInfo` — package identity comes from `transitive_packages` —
    # so an invented name would be unverifiable fiction.
    asserts.equals(env, "", info.package_name)
    asserts.equals(env, "", info.lib_root)

    # The forwarding half: identical to `dart_info()`'s. A facade that dropped
    # a dependency's closure would break the consumer that lists only it.
    srcs = _short_paths(info.transitive_srcs)
    resources = _short_paths(info.transitive_resources)
    asserts.true(
        env,
        [p for p in srcs if p.endswith("/lib/dep.dart")] != [],
        "dependency's source missing from transitive_srcs: %s" % srcs,
    )
    asserts.true(
        env,
        [p for p in resources if p.endswith("/lib/dep.yaml")] != [],
        "dependency's resource missing from transitive_resources: %s" % resources,
    )
    asserts.equals(env, 1, len(info.transitive_code_asset_files.to_list()))

    return analysistest.end(env)

no_package_test = analysistest.make(_no_package_test_impl)

def _no_package_empty_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartInfo]

    # `flutter_material_icons`'s exact shape: a font, no deps, and a provider
    # that contributes nothing to anything that lists it.
    asserts.equals(env, [], info.transitive_srcs.to_list())
    asserts.equals(env, [], info.transitive_resources.to_list())
    asserts.equals(env, [], info.transitive_packages.to_list())
    asserts.equals(env, [], info.transitive_code_asset_files.to_list())

    return analysistest.end(env)

no_package_empty_test = analysistest.make(_no_package_empty_test_impl)

def _analyzable_with_package_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    # Gaining a package costs none of the separation. `DartAnalyzableInfo`
    # exists so an executable is analyzable without becoming a legal `deps`
    # entry, and that has to survive the constructor that gives it a package —
    # otherwise the fix for `uri_does_not_exist` would quietly make every one of
    # these targets depable.
    asserts.true(
        env,
        DartAnalyzableInfo in target,
        "a package-contributing executable must provide DartAnalyzableInfo",
    )
    asserts.false(
        env,
        DartInfo in target,
        "it must NOT provide DartInfo — that is what `deps` requires",
    )
    if DartAnalyzableInfo not in target:
        return analysistest.end(env)

    analyzable = target[DartAnalyzableInfo]
    info = analyzable.dart_info

    # The whole point: the target's own package record reaches the nested
    # `DartInfo`. Without it nothing names `exec_pkg`, so `package:exec_pkg/…`
    # resolves against nothing and the analyzer reports `uri_does_not_exist` —
    # the symptom that sent a downstream rule set past these constructors.
    own = [
        p
        for p in info.transitive_packages.to_list()
        if p.package_name == "exec_pkg"
    ]
    asserts.equals(env, 1, len(own), "expected exactly one `exec_pkg` record")
    if len(own) != 1:
        return analysistest.end(env)
    asserts.true(
        env,
        own[0].lib_root.endswith("dart_info_fixture"),
        "the package record's lib_root is wrong: %s" % own[0].lib_root,
    )
    asserts.equals(env, "3.11", own[0].language_version)

    # The asset the executable's own package owns, on its own record. Every
    # parameter this constructor forwards is a line someone could delete without
    # a test noticing, and a dropped `code_assets` would strand the native
    # library the package ships.
    asserts.equals(
        env,
        ["package:exec_pkg/src/ffi/owned.g.dart"],
        sorted([a.asset_id for a in package_code_assets(own[0])]),
    )
    asserts.equals(env, 2, len(info.transitive_code_asset_files.to_list()))

    # And the dependency's record beside it: a package of its own must not cost
    # the merge that `dart_analyzable_info()` already did.
    names = sorted([p.package_name for p in info.transitive_packages.to_list()])
    asserts.equals(env, ["exec_pkg", "info_dep"], names)

    # The source split, which is the part a caller can get backwards silently.
    # The package's `lib/` file rides the nested `DartInfo`, where a
    # `package:` URI can reach it; the entrypoint rides the outer `srcs`, where
    # nothing needs to.
    srcs = _short_paths(info.transitive_srcs)
    resources = _short_paths(info.transitive_resources)
    asserts.true(
        env,
        [p for p in srcs if p.endswith("/lib/owned.dart")] != [],
        "the package's own lib/ source is missing from transitive_srcs: %s" % srcs,
    )
    asserts.true(
        env,
        [p for p in resources if p.endswith("/lib/owned.yaml")] != [],
        "the package's own resource is missing from transitive_resources: %s" % resources,
    )
    asserts.true(
        env,
        [p for p in srcs if p.endswith("/lib/dep.dart")] != [],
        "dependency's source missing from transitive_srcs: %s" % srcs,
    )
    asserts.true(
        env,
        [p for p in resources if p.endswith("/lib/dep.yaml")] != [],
        "dependency's resource missing from transitive_resources: %s" % resources,
    )

    # The entrypoint is in the outer field and *only* there: it belongs to no
    # package's `lib/`, so a `DartInfo` carrying it would be claiming a
    # `package:` URI reaches it.
    entry = sorted([f.short_path for f in analyzable.srcs.to_list()])
    asserts.equals(env, 1, len(entry), "expected exactly one entrypoint: %s" % entry)
    asserts.true(
        env,
        entry[0].endswith("/entry.dart"),
        "the entrypoint is missing from DartAnalyzableInfo.srcs: %s" % entry,
    )
    asserts.true(
        env,
        [p for p in srcs if p.endswith("/entry.dart")] == [],
        "the entrypoint leaked into transitive_srcs: %s" % srcs,
    )

    return analysistest.end(env)

analyzable_with_package_test = analysistest.make(_analyzable_with_package_test_impl)

def _no_package_name_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "`package_name` is empty")
    return analysistest.end(env)

# The redirect that keeps the two constructors from collapsing into one. An
# empty `package_name` means the caller wanted `dart_analyzable_info()`, and
# saying so is cheaper than the package record with no name that `dart_info()`
# would otherwise build.
no_package_name_test = analysistest.make(
    _no_package_name_test_impl,
    expect_failure = True,
)

def _misowned_asset_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is not namespaced to this package")
    return analysistest.end(env)

# The ownership check reaches callers outside rules_dart because it lives in the
# constructor rather than in `dart_library`'s implementation.
misowned_asset_test = analysistest.make(
    _misowned_asset_test_impl,
    expect_failure = True,
)

def _language_version_passthrough_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartInfo]

    own = [
        p
        for p in info.transitive_packages.to_list()
        if p.package_name == ctx.attr.expected_package
    ]
    asserts.equals(
        env,
        1,
        len(own),
        "expected exactly one record for %s" % ctx.attr.expected_package,
    )
    asserts.equals(
        env,
        ctx.attr.expected_language_version,
        own[0].language_version,
    )

    return analysistest.end(env)

# `language_version` is a required parameter of `dart_info()`, which is a claim
# about the *calling convention* and not about the value: a package that states
# no language version is still expressible, by answering `""`. These two cases
# are what says so — the stated value reaches the record, and the empty one
# produces a record carrying `""` rather than being rejected. If tightening the
# signature had narrowed the value space instead of the ways to call it, the
# empty case is what would break.
language_version_passthrough_test = analysistest.make(
    _language_version_passthrough_test_impl,
    attrs = {
        "expected_language_version": attr.string(),
        "expected_package": attr.string(mandatory = True),
    },
)
