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
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("//dart/private:common.bzl", "package_code_assets")
load("//dart/private:dart_info.bzl", "dart_info", "dart_info_no_package")

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
