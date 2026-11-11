"""Tests for declared data assets.

A `dart_data_asset` stands in for a `DataAsset` a package's build hook emits;
its package's `dart_package_metadata` names it in `data_assets`, which replace
the build hook and reach every program over the package. Every `fail()` is a
message a user reads, so each has a case asserting what it says.

The analysis tests are declared beside their fixtures, in
`//dart/tests/data_asset_fixture`; how link hooks receive the assets is
`link_hook_test`'s.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartDataAssetInfo", "DartInfo")
load("//dart/private:common.bzl", "merge_package_records", "package_data_assets", "program_packages", "unique_data_assets")
load("//dart/private:dart_data_asset.bzl", "data_asset")
load("//dart/private:dart_package_metadata.bzl", "unreplaced_build_hook")
load("//dart/private:package_info.bzl", "check_data_asset_ownership", "raw_dart_package_info")
load(":small_suite.bzl", "small_unittest_suite")

def _file(short_path):
    return struct(short_path = short_path)

# --- check_data_asset_ownership ---

def _ownership_test_impl(ctx):
    env = unittest.begin(ctx)
    own = data_asset("p", "a.txt", _file("p/a.txt"))
    asserts.equals(env, None, check_data_asset_ownership("//p:m", "p", [own]))

    err = check_data_asset_ownership("//p:m", "p", [data_asset("q", "a.txt", _file("q/a.txt"))])
    asserts.true(env, err != None and "`package:q/a.txt` is not namespaced" in err and "`package:p/`" in err, err)

    # Upstream's "More than one data asset with same name".
    err = check_data_asset_ownership("//p:m", "p", [own, data_asset("p", "a.txt", _file("p/b.txt"))])
    asserts.true(env, err != None and "declared twice" in err and "p/a.txt" in err and "p/b.txt" in err, err)
    return unittest.end(env)

_ownership_test = unittest.make(_ownership_test_impl)

# --- unreplaced_build_hook ---

def _data_assets_replace_hook_test_impl(ctx):
    # A build hook that emits only data assets is replaced by them, as one
    # building native code is by code assets.
    env = unittest.begin(ctx)
    asserts.equals(env, "", unreplaced_build_hook(struct(), [data_asset("p", "a", _file("a"))]))
    return unittest.end(env)

_data_assets_replace_hook_test = unittest.make(_data_assets_replace_hook_test_impl)

# --- merge_package_records ---

# Built raw, not through `DartPackageInfo(...)`: that takes the assets as targets, and
# these tests have values.
def _record(package_root, hook = "", data_assets = ()):
    return raw_dart_package_info(
        label = None,
        package_name = "split",
        package_root = package_root,
        version = "",
        language_version = "",
        code_assets = (),
        data_assets = data_assets,
        unreplaced_hook = hook,
        link_hook = None,
        link_hook_assets = (),
        linked_code_assets = (),
        license_file = None,
        metadata = None,
    )

def _merge_unions_data_assets_test_impl(ctx):
    # A package's records each carry its assets; the merged record has each
    # once, and they replace the hook another record flags, in either order.
    env = unittest.begin(ctx)
    a = data_asset("split", "a", _file("a"))
    b = data_asset("split", "b", _file("b"))
    merged = merge_package_records([
        _record("x", hook = "hook/build.dart", data_assets = (a,)),
        _record("y", data_assets = (a, b)),
    ])
    asserts.equals(env, (a, b), package_data_assets(merged[0]))
    asserts.equals(env, "", merged[0].unreplaced_hook)
    hooked = _record("x", hook = "hook/build.dart")
    replaced = _record("y", data_assets = (a,))
    asserts.equals(env, "", merge_package_records([hooked, replaced])[0].unreplaced_hook)
    asserts.equals(env, "", merge_package_records([replaced, hooked])[0].unreplaced_hook)
    return unittest.end(env)

_merge_unions_data_assets_test = unittest.make(_merge_unions_data_assets_test_impl)

def _one_file_per_id_test_impl(ctx):
    # Two hubs supplying one package can each name a file for one id: the
    # same file collapses, two different ones are an error naming both.
    env = unittest.begin(ctx)
    a = data_asset("split", "a", _file("x/a"))
    assets, err = unique_data_assets(merge_package_records([
        _record("x", data_assets = (a,)),
        _record("y", data_assets = (a,)),
    ]))
    asserts.equals(env, None, err)
    asserts.equals(env, [a], assets)
    _, err = unique_data_assets(merge_package_records([
        _record("x", data_assets = (a,)),
        _record("y", data_assets = (data_asset("split", "a", _file("y/a")),)),
    ]))
    asserts.true(env, err != None and "`package:split/a` names two files, `x/a` and `y/a`" in err, err)
    return unittest.end(env)

_one_file_per_id_test = unittest.make(_one_file_per_id_test_impl)

def _program_own_package_test_impl(ctx):
    # A program's own package ships its assets with no library of it in
    # `deps`, as a dependency's would.
    env = unittest.begin(ctx)
    a = data_asset("split", "a", _file("x/a"))
    asserts.equals(env, ([a], None), unique_data_assets(program_packages(_record("x", data_assets = (a,)), [])))
    asserts.equals(env, ([], None), unique_data_assets(program_packages(None, [])))
    return unittest.end(env)

_program_own_package_test = unittest.make(_program_own_package_test_impl)

# --- analysis tests ---

def _data_asset_provider_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    assets = target[DartDataAssetInfo].assets.to_list()
    asserts.equals(env, ["package:data_asset_fixture/greeting.txt"], [a.id for a in assets])
    asserts.equals(env, "data_asset_fixture", assets[0].package)
    asserts.equals(env, "greeting.txt", assets[0].name)
    asserts.equals(env, "greeting.txt", assets[0].file.basename)
    asserts.equals(env, [assets[0].file], target[DefaultInfo].files.to_list())
    return analysistest.end(env)

data_asset_provider_test = analysistest.make(_data_asset_provider_test_impl)

def _library_carries_data_assets_test_impl(ctx):
    # Declared on the metadata, carried by every record of the package, and
    # collected for a program over it; the hook they replace is not flagged.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    records = [
        p
        for p in target[DartInfo].transitive_packages.to_list()
        if p.package_name == "data_asset_fixture"
    ]
    asserts.equals(env, 1, len(records))
    asserts.equals(env, ["package:data_asset_fixture/greeting.txt"], [a.id for a in package_data_assets(records[0])])
    asserts.equals(env, "", records[0].unreplaced_hook)
    collected, _ = unique_data_assets(program_packages(None, [target]))
    asserts.equals(env, ["package:data_asset_fixture/greeting.txt"], [a.id for a in collected])
    return analysistest.end(env)

library_carries_data_assets_test = analysistest.make(_library_carries_data_assets_test_impl)

def _analyzes_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

replaced_hook_analyzes_test = analysistest.make(_analyzes_test_impl)

def _expect_failure(*fragments):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        for fragment in fragments:
            asserts.expect_failure(env, fragment)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

malformed_data_asset_id_test = _expect_failure("is not of the form `package:<package>/<name>`")
misowned_data_asset_test = _expect_failure("`package:data_asset_fixture/greeting.txt` is not namespaced to this package")
data_asset_declared_twice_test = _expect_failure("data asset id `package:twice/a.txt` is declared twice")

def data_asset_test_suite(name):
    """Registers the pure-helper unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    small_unittest_suite(
        name,
        _ownership_test,
        _data_assets_replace_hook_test,
        _merge_unions_data_assets_test,
        _one_file_per_id_test,
        _program_own_package_test,
    )
