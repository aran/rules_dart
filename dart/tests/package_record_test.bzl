"""Tests for how one package's records combine into the record a build uses.

A package reaches a target as several `DartPackageInfo` records — one per
`dart_library` of a package split across directories, one per pub hub
supplying it — and `merge_package_records` makes them one. Each package-level
fact is the package's, whichever record states it, and two records stating it
differently are an error naming both targets.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartPackageInfo")
load(
    "//dart/private:common.bzl",
    "merge_package_records",
    "package_agreement_error",
    "package_code_assets",
    "package_license_file",
    "package_link_hook",
)
load(":small_suite.bzl", "small_unittest_suite")

def _file(short_path):
    return struct(short_path = short_path)

def _asset(asset_id):
    return DartCodeAssetInfo(
        asset_id = asset_id,
        link_mode = "dynamic_loading_bundle",
        dynamic_library = struct(owner = "lib.so", path = "lib.so"),
        system_uri = "",
    )

def _pkg(
        label,
        package_name = "split",
        package_root = "pkg",
        version = "",
        language_version = "",
        code_assets = (),
        unreplaced_hook = "",
        link_hook = None,
        license_file = None):
    return DartPackageInfo(
        label = label,
        package_name = package_name,
        package_root = package_root,
        version = version,
        language_version = language_version,
        code_assets = code_assets,
        unreplaced_hook = unreplaced_hook,
        link_hook = link_hook,
        license_file = license_file,
    )

# --- merge_package_records: a fact stated on any record is the package's ---

def _merge_takes_stated_language_version_test_impl(ctx):
    # The bug: a split package whose first record states no language version
    # got none in `package_config.json`, and compiled under the current SDK's
    # rules despite its other target stating 3.7.
    env = unittest.begin(ctx)
    merged = merge_package_records([
        _pkg("//pkg/lib/a"),
        _pkg("//pkg/lib/b", language_version = "3.7"),
    ])
    asserts.equals(env, 1, len(merged))
    asserts.equals(env, "3.7", merged[0].language_version)
    asserts.equals(env, "//pkg/lib/a", merged[0].label)
    return unittest.end(env)

def _merge_takes_every_stated_fact_test_impl(ctx):
    # The same for every package-level field, each stated on a different
    # record and none on the first.
    env = unittest.begin(ctx)
    hook = _file("pkg/hook/link.dart")
    license = _file("pkg/LICENSE")
    merged = merge_package_records([
        _pkg("//pkg/lib/a"),
        _pkg("//pkg/lib/b", version = "1.2.3"),
        _pkg("//pkg/lib/c", link_hook = hook),
        _pkg("//pkg/lib/d", license_file = license),
        _pkg("//pkg/lib/e", unreplaced_hook = "hook/build.dart"),
    ])[0]
    asserts.equals(env, "1.2.3", merged.version)
    asserts.equals(env, hook, package_link_hook(merged))
    asserts.equals(env, license, package_license_file(merged))
    asserts.equals(env, "hook/build.dart", merged.unreplaced_hook)
    return unittest.end(env)

def _merge_keeps_a_complete_first_record_test_impl(ctx):
    # A duplicate that adds nothing leaves the first record as it was.
    env = unittest.begin(ctx)
    first = _pkg("//pkg/lib/a", language_version = "3.7", version = "1.0.0")
    merged = merge_package_records([first, _pkg("//pkg/lib/b", language_version = "3.7")])
    asserts.equals(env, first, merged[0])
    return unittest.end(env)

def _merge_order_does_not_decide_test_impl(ctx):
    env = unittest.begin(ctx)
    records = [
        _pkg("//pkg/lib/a", code_assets = (_asset("package:split/a.dart"),)),
        _pkg("//pkg/lib/b", language_version = "3.7", unreplaced_hook = "hook/build.dart"),
    ]
    forward = merge_package_records(records)[0]
    backward = merge_package_records(reversed(records))[0]
    for merged in (forward, backward):
        asserts.equals(env, "3.7", merged.language_version)
        asserts.equals(env, ["package:split/a.dart"], [a.asset_id for a in package_code_assets(merged)])

        # The assets replace the build hook, whichever record carries which.
        asserts.equals(env, "", merged.unreplaced_hook)
    return unittest.end(env)

# --- package_agreement_error: two stated values are an error naming both ---

def _agreement_names_both_targets_test_impl(ctx):
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("//pkg/lib/a", language_version = "3.7"),
        _pkg("//pkg/lib/b"),
        _pkg("//pkg/lib/c", language_version = "3.4"),
    ])
    asserts.true(env, err != None, "disagreeing language versions must be reported")
    for part in ["3.7 (//pkg/lib/a at pkg)", "3.4 (//pkg/lib/c at pkg)"]:
        asserts.true(env, part in err, "%s not in: %s" % (part, err))
    asserts.true(env, "//pkg/lib/b" not in err, "a record stating nothing is not named: %s" % err)
    return unittest.end(env)

def _agreement_rejects_two_link_hooks_test_impl(ctx):
    # Before, the first hook ran and the second was silently dropped.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("//pkg:a", link_hook = _file("pkg/hook/link.dart")),
        _pkg("//pkg:b", link_hook = _file("pkg/tool/link.dart")),
    ])
    asserts.true(env, err != None, "two link hooks must be reported")
    for part in ["link hooks", "hook/link.dart (//pkg:a at pkg)", "tool/link.dart (//pkg:b at pkg)", "`dart_library.link_hook`"]:
        asserts.true(env, part in err, "%s not in: %s" % (part, err))
    return unittest.end(env)

def _agreement_accepts_one_link_hook_from_two_hubs_test_impl(ctx):
    # Two hubs fetch one package twice: different Files, one hook.
    env = unittest.begin(ctx)
    asserts.equals(env, None, package_agreement_error([
        _pkg("@hub_a//ffi", package_name = "ffi", package_root = "../hub_a__ffi", link_hook = _file("../hub_a__ffi/hook/link.dart")),
        _pkg("@hub_b//ffi", package_name = "ffi", package_root = "../hub_b__ffi", link_hook = _file("../hub_b__ffi/hook/link.dart")),
    ]))
    return unittest.end(env)

def _agreement_rejects_two_build_hooks_test_impl(ctx):
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("//pkg:a", unreplaced_hook = "hook/build.dart"),
        _pkg("//pkg:b", unreplaced_hook = "tool/build.dart"),
    ])
    asserts.true(env, err != None and "build hooks" in err, str(err))
    return unittest.end(env)

def _agreement_falls_back_to_root_without_label_test_impl(ctx):
    # A record from a producer predating `label` is named by its root.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        struct(package_name = "p", package_root = "first", language_version = "3.7"),
        struct(package_name = "p", package_root = "second", language_version = "3.4"),
    ])
    asserts.true(env, err != None and "3.7 (first)" in err and "3.4 (second)" in err, str(err))
    return unittest.end(env)

_merge_takes_stated_language_version_test = unittest.make(_merge_takes_stated_language_version_test_impl)
_merge_takes_every_stated_fact_test = unittest.make(_merge_takes_every_stated_fact_test_impl)
_merge_keeps_a_complete_first_record_test = unittest.make(_merge_keeps_a_complete_first_record_test_impl)
_merge_order_does_not_decide_test = unittest.make(_merge_order_does_not_decide_test_impl)
_agreement_names_both_targets_test = unittest.make(_agreement_names_both_targets_test_impl)
_agreement_rejects_two_link_hooks_test = unittest.make(_agreement_rejects_two_link_hooks_test_impl)
_agreement_accepts_one_link_hook_from_two_hubs_test = unittest.make(_agreement_accepts_one_link_hook_from_two_hubs_test_impl)
_agreement_rejects_two_build_hooks_test = unittest.make(_agreement_rejects_two_build_hooks_test_impl)
_agreement_falls_back_to_root_without_label_test = unittest.make(_agreement_falls_back_to_root_without_label_test_impl)

def package_record_test_suite(name):
    """Declares the package-record merge unit tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name,
        _merge_takes_stated_language_version_test,
        _merge_takes_every_stated_fact_test,
        _merge_keeps_a_complete_first_record_test,
        _merge_order_does_not_decide_test,
        _agreement_names_both_targets_test,
        _agreement_rejects_two_link_hooks_test,
        _agreement_accepts_one_link_hook_from_two_hubs_test,
        _agreement_rejects_two_build_hooks_test,
        _agreement_falls_back_to_root_without_label_test,
    )

# --- through real rules: `split_package_fixture` ---

def _package_config_language_version_test_impl(ctx):
    env = analysistest.begin(ctx)
    content = None
    for action in analysistest.target_actions(env):
        for out in action.outputs.to_list():
            if out.basename.endswith(".package_config.json"):
                content = action.content
    asserts.true(env, content != None, "expected a package_config.json write action")
    entry = json.decode(content)["packages"]
    entry = [p for p in entry if p["name"] == ctx.attr.package_name]
    asserts.equals(env, 1, len(entry), content)
    asserts.equals(env, ctx.attr.expected_language_version, entry[0].get("languageVersion"), content)
    return analysistest.end(env)

package_config_language_version_test = analysistest.make(
    _package_config_language_version_test_impl,
    attrs = {
        "expected_language_version": attr.string(mandatory = True),
        "package_name": attr.string(mandatory = True),
    },
)

def _language_version_conflict_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "split_package_fixture/lib/other_version:other_version at dart/tests/split_package_fixture")
    asserts.expect_failure(env, "split_package_fixture/lib/versioned:versioned at dart/tests/split_package_fixture")
    return analysistest.end(env)

language_version_conflict_test = analysistest.make(
    _language_version_conflict_test_impl,
    expect_failure = True,
)
