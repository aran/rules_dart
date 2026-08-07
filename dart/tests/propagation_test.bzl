"""Tests for code-asset propagation through the Dart package graph.

The central claim: a code asset declared on the `dart_library` of the package
that owns it reaches every `dart_binary`/`dart_test` depending on that package,
directly or transitively — matching upstream, where depending on a package
gets you its assets with no opt-in.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartPackageInfo")
load("//dart/private:common.bzl", "merge_package_records", "package_code_assets", "resolve_code_assets")
load(":small_suite.bzl", "small_unittest_suite")

_L = "//pkg:consumer"

def _asset(asset_id, owner_path = "libfoo.so", link_mode = "dynamic_loading_bundle", system_uri = ""):
    """A DartCodeAssetInfo stand-in.

    `dynamic_library` needs only an `owner`, since `resolve_code_assets`
    compares producing targets rather than `File`s.
    """
    library = None
    if link_mode == "dynamic_loading_bundle":
        library = struct(owner = owner_path)
    return DartCodeAssetInfo(
        asset_id = asset_id,
        link_mode = link_mode,
        dynamic_library = library,
        system_uri = system_uri,
    )

def _pkg(package_name, lib_root, code_assets = ()):
    return DartPackageInfo(
        package_name = package_name,
        lib_root = lib_root,
        language_version = "",
        code_assets = code_assets,
    )

# --- resolve_code_assets ---

def _resolve_dedups_diamond_test_impl(ctx):
    # The same asset arriving twice — the diamond — collapses to one entry.
    env = unittest.begin(ctx)
    a = _asset("package:sqlite3/ffi.g.dart")
    result = resolve_code_assets(_L, [a, a], [])
    asserts.equals(env, 1, len(result))
    asserts.equals(env, "package:sqlite3/ffi.g.dart", result[0].asset_id)
    return unittest.end(env)

def _resolve_explicit_matching_transitive_test_impl(ctx):
    # Naming explicitly what a dependency already supplies is not a conflict.
    env = unittest.begin(ctx)
    a = _asset("package:sqlite3/ffi.g.dart")
    result = resolve_code_assets(_L, [a], [_asset("package:sqlite3/ffi.g.dart")])
    asserts.equals(env, 1, len(result))
    return unittest.end(env)

def _resolve_unions_distinct_test_impl(ctx):
    env = unittest.begin(ctx)
    result = resolve_code_assets(
        _L,
        [_asset("package:a/a.g.dart", "liba.so")],
        [_asset("package:b/b.g.dart", "libb.so")],
    )
    asserts.equals(env, 2, len(result))
    asserts.equals(env, ["package:a/a.g.dart", "package:b/b.g.dart"], [r.asset_id for r in result])
    return unittest.end(env)

def _resolve_keeps_non_bundle_modes_test_impl(ctx):
    env = unittest.begin(ctx)
    result = resolve_code_assets(_L, [
        _asset("package:a/a.g.dart", link_mode = "dynamic_loading_system", system_uri = "liba.so.0"),
        _asset("package:b/b.g.dart", link_mode = "dynamic_loading_process"),
    ], [])
    asserts.equals(env, 2, len(result))
    asserts.equals(env, None, result[0].dynamic_library)
    asserts.equals(env, "liba.so.0", result[0].system_uri)
    return unittest.end(env)

# --- merge_package_records: dedup and asset union ---

def _two_hubs_supply_one_package_test_impl(ctx):
    # Regression: two independent pub hubs — rules_flutter's `flutter.pub()`
    # and rules_dart's `pub.from_lock()` — each generate a spoke for `ffi`,
    # giving one package name two `lib_root`s. This is normal, not an error.
    # The same shape arises from a package deliberately split across
    # `dart_library` targets, which `colocate_packages` exists to support.
    env = unittest.begin(ctx)
    packages = merge_package_records([
        _pkg("ffi", "../rules_flutter++flutter+deps__ffi"),
        _pkg("ffi", "../rules_dart++pub+dart_pub__ffi"),
        _pkg("meta", "../rules_flutter++flutter+deps__meta"),
        _pkg("meta", "../rules_dart++pub+dart_pub__meta"),
    ])
    asserts.equals(env, ["ffi", "meta"], [p.package_name for p in packages])

    # First record wins for source resolution, as it always has.
    asserts.equals(env, "../rules_flutter++flutter+deps__ffi", packages[0].lib_root)
    return unittest.end(env)

def _unions_assets_across_differing_roots_test_impl(ctx):
    # Differing roots must still not lose assets: that silent drop is the one
    # thing the dedup can get wrong, and it surfaces at runtime as an
    # unresolved @Native symbol rather than at build time.
    env = unittest.begin(ctx)
    packages = merge_package_records([
        _pkg("split", "first/split", (_asset("package:split/a.g.dart", "liba.so"),)),
        _pkg("split", "second/split", (_asset("package:split/b.g.dart", "libb.so"),)),
    ])
    asserts.equals(env, 1, len(packages))
    ids = [a.asset_id for a in package_code_assets(packages[0])]
    asserts.equals(env, ["package:split/a.g.dart", "package:split/b.g.dart"], ids)
    return unittest.end(env)

def _collect_unions_same_root_assets_test_impl(ctx):
    # Two dart_library targets splitting one package must not lose the second
    # one's assets to first-wins dedup.
    env = unittest.begin(ctx)
    packages = merge_package_records([
        _pkg("shared", "pkgs/shared", (_asset("package:shared/a.g.dart", "liba.so"),)),
        _pkg("shared", "pkgs/shared", (_asset("package:shared/b.g.dart", "libb.so"),)),
    ])
    asserts.equals(env, 1, len(packages))
    ids = [a.asset_id for a in package_code_assets(packages[0])]
    asserts.equals(env, ["package:shared/a.g.dart", "package:shared/b.g.dart"], ids)
    return unittest.end(env)

def _union_keeps_other_fields_test_impl(ctx):
    # The union branch rebuilds the kept record. Everything it was carrying
    # besides the assets has to survive that rebuild — `language_version`
    # wrong means a package compiles under the wrong Dart semantics, and a
    # lost `has_unreplaced_hook` means the build stops warning about a native
    # library that will not be there at runtime.
    env = unittest.begin(ctx)
    kept = DartPackageInfo(
        package_name = "dual",
        lib_root = "first/dual",
        language_version = "3.4",
        code_assets = (_asset("package:dual/a.g.dart"),),
        has_unreplaced_hook = "hook/build.dart",
    )
    packages = merge_package_records([
        kept,
        _pkg("dual", "second/dual", (_asset("package:dual/b.g.dart", "libb.so"),)),
    ])
    asserts.equals(env, 1, len(packages))
    asserts.equals(env, "first/dual", packages[0].lib_root)
    asserts.equals(env, "3.4", packages[0].language_version)
    asserts.equals(env, "hook/build.dart", packages[0].has_unreplaced_hook)
    asserts.equals(
        env,
        ["package:dual/a.g.dart", "package:dual/b.g.dart"],
        [a.asset_id for a in package_code_assets(packages[0])],
    )
    return unittest.end(env)

def _collect_tolerates_missing_field_test_impl(ctx):
    # DartPackageInfo produced outside rules_dart (rules_flutter builds its
    # own) omits `code_assets`; that must not crash the collector.
    env = unittest.begin(ctx)
    packages = merge_package_records([
        DartPackageInfo(package_name = "legacy", lib_root = "legacy"),
    ])
    asserts.equals(env, 1, len(packages))
    asserts.equals(env, (), package_code_assets(packages[0]))
    return unittest.end(env)

# --- end-to-end propagation through real rules ---

def _diamond_probe_impl(ctx):
    infos = [dep[DartInfo] for dep in ctx.attr.deps]
    ids = []
    for info in infos:
        for pkg in info.transitive_packages.to_list():
            ids.extend([a.asset_id for a in package_code_assets(pkg)])
    files = depset(transitive = [i.transitive_code_asset_files for i in infos]).to_list()
    if sorted(ids) != sorted(ctx.attr.expected_asset_ids):
        fail("%s: expected asset ids %s, propagated %s" %
             (ctx.label, sorted(ctx.attr.expected_asset_ids), sorted(ids)))
    if len(files) != ctx.attr.expected_file_count:
        fail("%s: expected %d code-asset file(s) in DartInfo, got %s" %
             (ctx.label, ctx.attr.expected_file_count, [f.short_path for f in files]))
    return [DefaultInfo(files = depset(files))]

diamond_probe = rule(
    implementation = _diamond_probe_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "expected_asset_ids": attr.string_list(),
        "expected_file_count": attr.int(),
    },
    doc = "Asserts which code assets a `dart_library` graph propagates.",
)

def _manifest_contains_test_impl(ctx):
    """Asserts the binary's generated native_assets.yaml names the asset.

    The probe above proves the provider graph carries the asset; this proves
    the terminal rule actually writes it into the manifest `gen_kernel`
    embeds — which is what makes it resolvable at runtime.
    """
    env = analysistest.begin(ctx)
    manifests = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith(".native_assets.yaml")
    ]
    asserts.equals(env, 1, len(manifests), "expected exactly one native_assets.yaml write action")
    content = manifests[0].content
    for asset_id in ctx.attr.expected_asset_ids:
        asserts.true(env, ('"%s"' % asset_id) in content, "%s missing from manifest: %s" % (asset_id, content))
    return analysistest.end(env)

manifest_contains_test = analysistest.make(
    _manifest_contains_test_impl,
    attrs = {"expected_asset_ids": attr.string_list()},
)

def _ownership_violation_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is not namespaced to this package")
    return analysistest.end(env)

ownership_violation_test = analysistest.make(
    _ownership_violation_test_impl,
    expect_failure = True,
)

def _asset_conflict_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is claimed twice with different definitions")
    return analysistest.end(env)

asset_conflict_test = analysistest.make(
    _asset_conflict_test_impl,
    expect_failure = True,
)

_t0_test = unittest.make(_resolve_dedups_diamond_test_impl)
_t1_test = unittest.make(_resolve_explicit_matching_transitive_test_impl)
_t2_test = unittest.make(_resolve_unions_distinct_test_impl)
_t3_test = unittest.make(_resolve_keeps_non_bundle_modes_test_impl)
_t4_test = unittest.make(_collect_unions_same_root_assets_test_impl)
_t5_test = unittest.make(_collect_tolerates_missing_field_test_impl)
_t6_test = unittest.make(_two_hubs_supply_one_package_test_impl)
_t7_test = unittest.make(_unions_assets_across_differing_roots_test_impl)
_t8_test = unittest.make(_union_keeps_other_fields_test_impl)

def propagation_test_suite(name):
    """Declares the code-asset propagation unit tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
    )
