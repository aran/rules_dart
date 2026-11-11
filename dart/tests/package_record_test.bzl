"""Tests for how one package's records combine into the record a build uses.

A package reaches a target as several `DartPackageInfo` records — one per
target of the package, one per pub hub supplying it — and
`merge_package_records` makes them one. Records at one root must name the same
`dart_package_metadata`; records of two producers are compared by value, and
two stating a fact differently are an error naming both targets.
`merged_package_record` is the same merge for a target that is itself a
package.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartPackageMetadataInfo")
load(
    "//dart/private:common.bzl",
    "collect_packages",
    "merge_package_records",
    "merged_package_record",
    "package_agreement_error",
    "package_code_assets",
    "package_license_file",
    "package_link_hook",
)
load("//dart/private:dart_info.bzl", "package_info_from_metadata")
load("//dart/private:package_info.bzl", "check_linked_code_asset_ownership", "raw_dart_package_info")
load(":small_suite.bzl", "small_unittest_suite")

def _file(short_path):
    return struct(short_path = short_path)

def _asset(asset_id):
    return DartCodeAssetInfo(
        asset_id = asset_id,
        link_mode = "dynamic_loading_bundle",
        file = struct(owner = "lib.so", path = "lib.so"),
        uri = "",
    )

# Built raw, not through `DartPackageInfo(...)`: that takes the assets as targets, and
# these tests have values.
# It also states `metadata`, which `DartPackageInfo(...)` does not take.
def _pkg(
        label,
        package_name = "split",
        package_root = "pkg",
        version = "",
        language_version = "",
        code_assets = (),
        unreplaced_hook = "",
        link_hook = None,
        link_hook_assets = (),
        linked_code_assets = (),
        license_file = None,
        metadata = None):
    return raw_dart_package_info(
        label = label,
        package_name = package_name,
        package_root = package_root,
        version = version,
        language_version = language_version,
        code_assets = code_assets,
        unreplaced_hook = unreplaced_hook,
        data_assets = (),
        link_hook = link_hook,
        link_hook_assets = link_hook_assets,
        linked_code_assets = linked_code_assets,
        license_file = license_file,
        metadata = metadata,
    )

def _meta(label, package_name = "app", package_root = "app", language_version = "", version = "", code_assets = (), link_hook = None, link_hook_assets = (), license_file = None):
    return DartPackageMetadataInfo(
        label = label,
        package_name = package_name,
        package_root = package_root,
        language_version = language_version,
        version = version,
        code_assets = code_assets,
        data_assets = (),
        unreplaced_hook = "",
        link_hook = link_hook,
        link_hook_assets = link_hook_assets,
        linked_code_assets = (),
        license_file = license_file,
    )

# --- merge_package_records: a fact stated on any record is the package's ---

def _merge_takes_stated_language_version_test_impl(ctx):
    # Records naming no declaration, as a rule author's `DartPackageInfo(...)`
    # builds them: a first record stating no language version must not leave
    # the package with none in `package_config.json`.
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
        _pkg("//pkg/lib/f", link_hook = hook, link_hook_assets = ("package:split/index.json",)),
    ])[0]
    asserts.equals(env, "1.2.3", merged.version)
    asserts.equals(env, hook, package_link_hook(merged))
    asserts.equals(env, ("package:split/index.json",), merged.link_hook_assets)
    asserts.equals(env, license, package_license_file(merged))
    asserts.equals(env, "hook/build.dart", merged.unreplaced_hook)
    return unittest.end(env)

def _merge_unions_linked_code_assets_test_impl(ctx):
    # Native code linked per program unions as code assets do: dropping one
    # record's would leave its bindings unresolved.
    env = unittest.begin(ctx)
    a = struct(asset_id = "package:split/a")
    b = struct(asset_id = "package:split/b")
    merged = merge_package_records([
        _pkg("//pkg/lib/a", linked_code_assets = (a,)),
        _pkg("//pkg/lib/b", linked_code_assets = (b, a)),
    ])[0]
    asserts.equals(env, (a, b), merged.linked_code_assets)
    return unittest.end(env)

_merge_unions_linked_code_assets_test = unittest.make(_merge_unions_linked_code_assets_test_impl)

def _linked_code_asset_ownership_test_impl(ctx):
    env = unittest.begin(ctx)
    native = struct(asset_id = "package:app/native")
    asserts.equals(env, None, check_linked_code_asset_ownership("//app:m", "app", [native], []))
    err = check_linked_code_asset_ownership("//app:m", "app", [struct(asset_id = "package:other/native")], [])
    asserts.true(env, "linked code asset id `package:other/native` is not namespaced to this package" in err, err)
    err = check_linked_code_asset_ownership("//app:m", "app", [native], [_asset("package:app/native")])
    asserts.true(env, "code asset id `package:app/native` is declared twice: a package's `code_assets` and `linked_code_assets` name each id once." in err, err)
    return unittest.end(env)

_linked_code_asset_ownership_test = unittest.make(_linked_code_asset_ownership_test_impl)

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
    for part in ["link hooks", "hook/link.dart (//pkg:a at pkg)", "tool/link.dart (//pkg:b at pkg)", "`link_hook`"]:
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

def _agreement_rejects_two_link_hook_asset_lists_test_impl(ctx):
    # One hook, two statements of what it emits: dependency order would pick
    # the outputs Bazel declares.
    env = unittest.begin(ctx)
    hook = _file("pkg/hook/link.dart")
    err = package_agreement_error([
        _pkg("//pkg:a", link_hook = hook, link_hook_assets = ("package:split/a.json",)),
        _pkg("//pkg:b", link_hook = hook, link_hook_assets = ("package:split/b.json",)),
        _pkg("//pkg:c", link_hook = hook),
    ])
    asserts.true(env, err != None, "two link-hook asset lists must be reported")
    for part in ["link-hook assets", "package:split/a.json (//pkg:a at pkg)", "package:split/b.json (//pkg:b at pkg)", "`link_hook_assets`"]:
        asserts.true(env, part in err, "%s not in: %s" % (part, err))
    asserts.true(env, "//pkg:c" not in err, "a record stating none is not named: %s" % err)
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
    # A record with no `label` (a package no target stated) is named by its root.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg(None, package_name = "p", package_root = "first", language_version = "3.7"),
        _pkg(None, package_name = "p", package_root = "second", language_version = "3.4"),
    ])
    asserts.true(env, err != None and "3.7 (first)" in err and "3.4 (second)" in err, str(err))
    return unittest.end(env)

# --- one package, one declaration ---

def _agreement_rejects_two_declarations_at_one_root_test_impl(ctx):
    # Two targets of one package naming different declarations, or one naming
    # none: the message names each declaration and a target naming it.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("//pkg:a", metadata = "//pkg:pubspec"),
        _pkg("//pkg:b", metadata = "//pkg:other"),
        _pkg("//pkg:c"),
    ])
    asserts.true(env, err != None, "expected an error")
    asserts.true(env, "The package rooted at `pkg` is built by targets naming different `dart_package_metadata`:\n  - none (package \"split\"), named by //pkg:c\n  - //pkg:other (package \"split\"), named by //pkg:b\n  - //pkg:pubspec (package \"split\"), named by //pkg:a\n" in err, err)
    return unittest.end(env)

def _agreement_rejects_two_packages_declared_at_one_root_test_impl(ctx):
    # Two declarations for one root stating different package names: one
    # directory is one package, so the two are refused, not merged apart.
    env = unittest.begin(ctx)
    err = package_agreement_error([
        _pkg("//pkg:a", metadata = "//pkg:pubspec"),
        _pkg("//pkg:b", package_name = "renamed", metadata = "//pkg:other"),
    ])
    asserts.true(env, err != None, "expected an error")
    asserts.true(env, "  - //pkg:other (package \"renamed\"), named by //pkg:b\n  - //pkg:pubspec (package \"split\"), named by //pkg:a\n" in err, err)
    return unittest.end(env)

def _agreement_accepts_two_hubs_declarations_test_impl(ctx):
    # Two pub hubs each declare the package in their own spoke: different
    # roots, compared by value.
    env = unittest.begin(ctx)
    asserts.equals(env, None, package_agreement_error([
        _pkg("@a//:split", package_root = "../a", version = "1.0.0", metadata = "@a//:pubspec"),
        _pkg("@b//:split", package_root = "../b", version = "1.0.0", metadata = "@b//:pubspec"),
    ]))
    return unittest.end(env)

# --- merged_package_record ---

def _merged_record_without_records_is_fresh_test_impl(ctx):
    env = unittest.begin(ctx)
    record = merged_package_record("//app", "app", "app", _meta("//app:pubspec", language_version = "3.7"), [])
    asserts.equals(env, "//app", record.label)
    asserts.equals(env, "app", record.package_name)
    asserts.equals(env, "app", record.package_root)
    asserts.equals(env, "3.7", record.language_version)
    asserts.equals(env, "//app:pubspec", record.metadata)
    asserts.equals(env, (), record.code_assets)
    asserts.equals(env, None, record.link_hook)
    return unittest.end(env)

def _merged_record_carries_every_field_test_impl(ctx):
    env = unittest.begin(ctx)
    hook = _file("app/hook/link.dart")
    license = _file("app/LICENSE")
    meta = _meta(
        "//app:pubspec",
        language_version = "3.7",
        version = "1.0.0",
        code_assets = (_asset("package:app/a.dart"),),
        link_hook = hook,
        link_hook_assets = ("package:app/index.json",),
        license_file = license,
    )
    record = merged_package_record("//app", "app", "app", meta, [
        package_info_from_metadata("//app/lib/a", meta, "app"),
        package_info_from_metadata("//app/lib/b", meta, "app"),
    ])
    asserts.equals(env, "//app", record.label)
    asserts.equals(env, "3.7", record.language_version)
    asserts.equals(env, "1.0.0", record.version)
    asserts.equals(env, ["package:app/a.dart"], [a.asset_id for a in record.code_assets])
    asserts.equals(env, hook, record.link_hook)
    asserts.equals(env, ("package:app/index.json",), record.link_hook_assets)
    asserts.equals(env, license, record.license_file)
    return unittest.end(env)

def _merged_record_without_declaration_is_name_only_test_impl(ctx):
    # A target naming no declaration states nothing but its name.
    env = unittest.begin(ctx)
    record = merged_package_record("//app", "app", "app", None, [])
    asserts.equals(env, "", record.language_version)
    asserts.equals(env, None, record.metadata)
    return unittest.end(env)

_merge_takes_stated_language_version_test = unittest.make(_merge_takes_stated_language_version_test_impl)
_merge_takes_every_stated_fact_test = unittest.make(_merge_takes_every_stated_fact_test_impl)
_merge_keeps_a_complete_first_record_test = unittest.make(_merge_keeps_a_complete_first_record_test_impl)
_merge_order_does_not_decide_test = unittest.make(_merge_order_does_not_decide_test_impl)
_agreement_names_both_targets_test = unittest.make(_agreement_names_both_targets_test_impl)
_agreement_rejects_two_link_hooks_test = unittest.make(_agreement_rejects_two_link_hooks_test_impl)
_agreement_accepts_one_link_hook_from_two_hubs_test = unittest.make(_agreement_accepts_one_link_hook_from_two_hubs_test_impl)
_agreement_rejects_two_link_hook_asset_lists_test = unittest.make(_agreement_rejects_two_link_hook_asset_lists_test_impl)
_agreement_rejects_two_build_hooks_test = unittest.make(_agreement_rejects_two_build_hooks_test_impl)
_agreement_falls_back_to_root_without_label_test = unittest.make(_agreement_falls_back_to_root_without_label_test_impl)
_merged_record_without_records_is_fresh_test = unittest.make(_merged_record_without_records_is_fresh_test_impl)
_merged_record_carries_every_field_test = unittest.make(_merged_record_carries_every_field_test_impl)
_merged_record_without_declaration_is_name_only_test = unittest.make(_merged_record_without_declaration_is_name_only_test_impl)
_agreement_rejects_two_declarations_at_one_root_test = unittest.make(_agreement_rejects_two_declarations_at_one_root_test_impl)
_agreement_rejects_two_packages_declared_at_one_root_test = unittest.make(_agreement_rejects_two_packages_declared_at_one_root_test_impl)
_agreement_accepts_two_hubs_declarations_test = unittest.make(_agreement_accepts_two_hubs_declarations_test_impl)

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
        _merge_unions_linked_code_assets_test,
        _linked_code_asset_ownership_test,
        _merge_order_does_not_decide_test,
        _agreement_names_both_targets_test,
        _agreement_rejects_two_link_hooks_test,
        _agreement_rejects_two_link_hook_asset_lists_test,
        _agreement_accepts_one_link_hook_from_two_hubs_test,
        _agreement_rejects_two_build_hooks_test,
        _agreement_falls_back_to_root_without_label_test,
        _merged_record_without_records_is_fresh_test,
        _merged_record_carries_every_field_test,
        _merged_record_without_declaration_is_name_only_test,
        _agreement_rejects_two_declarations_at_one_root_test,
        _agreement_rejects_two_packages_declared_at_one_root_test,
        _agreement_accepts_two_hubs_declarations_test,
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

def _declaration_conflict_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

declaration_conflict_test = analysistest.make(
    _declaration_conflict_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)

def _app_record_probe_impl(ctx):
    """Builds the record a target that is itself a package would contribute."""
    root = ctx.attr.package_root
    metadata = ctx.attr.package[DartPackageMetadataInfo] if ctx.attr.package else None
    record = merged_package_record(
        ctx.label,
        ctx.attr.package_name,
        root,
        metadata,
        [p for p in collect_packages(ctx.attr.deps) if p.package_root == root],
    )
    if record.language_version != ctx.attr.expected_language_version:
        fail("%s: expected language_version %r, got %r" % (ctx.label, ctx.attr.expected_language_version, record.language_version))
    return [DefaultInfo()]

app_record_probe = rule(
    implementation = _app_record_probe_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "expected_language_version": attr.string(),
        "package": attr.label(providers = [DartPackageMetadataInfo]),
        "package_name": attr.string(mandatory = True),
        "package_root": attr.string(mandatory = True),
    },
    doc = "Calls `merged_package_record` on the records its deps root at `package_root`.",
)
