"""Tests for recorded uses and link hooks.

`dart_binary(record_use = True)` has two shapes — the compiler records in the
modes that tree-shake, and an empty file stands in for the others — and each
compile pipeline (direct, and via gen_kernel for code assets) must carry the
flag to the one action that records. `dart_link_hook` runs one action per
package with a hook and declares exactly the data assets named in
`data_assets`. Every `fail()` it can raise is a message a user reads, so each
has a case asserting what it says.

The pure helpers are unit tests; the rule shapes are `analysistest`s over
`//dart/tests/link_hook_fixture`, where nothing is ever built.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartDataAssetInfo", "DartInfo", "DartRecordedUsesInfo")
load("//dart/private:common.bzl", "merge_package_records", "package_link_hook")
load("//dart/private:dart_compile.bzl", "recorded_uses_kind")
load("//dart/private:dart_library.bzl", "link_hook_error")
load(
    "//dart/private:dart_link_hook.bzl",
    "link_hook_package_root",
    "parse_data_asset_ids",
    "recorded_uses_file_error",
)

# buildifier: disable=bzl-visibility
load("//dart/pub/private:build_content.bzl", "classify_pub_hooks", "make_dart_library_build_content")
load(":small_suite.bzl", "small_unittest_suite")

# --- recorded_uses_kind ---

def _kind_by_mode_test_impl(ctx):
    # Only the tree-shaking modes know which uses survive.
    env = unittest.begin(ctx)
    asserts.equals(env, "aot", recorded_uses_kind("exe"))
    asserts.equals(env, "aot", recorded_uses_kind("aot-snapshot"))
    asserts.equals(env, "empty", recorded_uses_kind("kernel"))
    asserts.equals(env, "empty", recorded_uses_kind("jit-snapshot"))
    return unittest.end(env)

_kind_by_mode_test = unittest.make(_kind_by_mode_test_impl)

# --- parse_data_asset_ids ---

def _parses_ids_test_impl(ctx):
    env = unittest.begin(ctx)
    assets, err = parse_data_asset_ids("//a:b", [
        "package:glyphs/glyphs/index.json",
        "package:other/top.json",
    ])
    asserts.equals(env, None, err)
    asserts.equals(env, ["glyphs", "other"], [a.package for a in assets])
    asserts.equals(env, ["glyphs/index.json", "top.json"], [a.name for a in assets])
    asserts.equals(env, "package:glyphs/glyphs/index.json", assets[0].id)
    return unittest.end(env)

_parses_ids_test = unittest.make(_parses_ids_test_impl)

def _rejects_malformed_ids_test_impl(ctx):
    # The name becomes an output path under the target, so anything that is
    # not a plain relative path is refused before it can escape it.
    env = unittest.begin(ctx)
    for bad in [
        "glyphs/index.json",
        "package:glyphs",
        "package:glyphs/",
        "package:/index.json",
        "package:glyphs/../escape.json",
        "package:glyphs/a//b.json",
        "package:glyphs/./a.json",
    ]:
        assets, err = parse_data_asset_ids("//a:b", [bad])
        asserts.equals(env, None, assets, bad)
        asserts.true(env, err != None and "is not of the form" in err, "%s: %s" % (bad, err))
    return unittest.end(env)

_rejects_malformed_ids_test = unittest.make(_rejects_malformed_ids_test_impl)

def _rejects_duplicate_ids_test_impl(ctx):
    env = unittest.begin(ctx)
    _, err = parse_data_asset_ids("//a:b", ["package:p/x.json", "package:p/x.json"])
    asserts.true(env, err != None and "declared twice" in err, err)
    return unittest.end(env)

_rejects_duplicate_ids_test = unittest.make(_rejects_duplicate_ids_test_impl)

# --- recorded_uses_file_error ---

def _recorded_uses_file_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, recorded_uses_file_error("//a:b", [
        struct(extension = "json", short_path = "uses.json"),
    ]))
    for files in [
        [],
        [struct(extension = "", short_path = "app")],
        [
            struct(extension = "json", short_path = "a.json"),
            struct(extension = "json", short_path = "b.json"),
        ],
    ]:
        err = recorded_uses_file_error("//a:b", files)
        asserts.true(env, err != None and "DartRecordedUsesInfo" in err, err)
    return unittest.end(env)

_recorded_uses_file_test = unittest.make(_recorded_uses_file_test_impl)

# --- link_hook_package_root / link_hook_error ---

def _package_root_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "glyphs", link_hook_package_root(struct(path = "glyphs/hook/link.dart")))
    asserts.equals(
        env,
        "external/hub__glyphs",
        link_hook_package_root(struct(path = "external/hub__glyphs/hook/link.dart")),
    )
    asserts.equals(env, ".", link_hook_package_root(struct(path = "hook/link.dart")))
    return unittest.end(env)

_package_root_test = unittest.make(_package_root_test_impl)

def _link_hook_location_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, link_hook_error("//a:b", "pkg", None))
    asserts.equals(env, None, link_hook_error("//a:b", "pkg", struct(short_path = "pkg/hook/link.dart")))
    asserts.equals(env, None, link_hook_error("//a:b", "", struct(short_path = "hook/link.dart")))
    err = link_hook_error("//a:b", "pkg", struct(short_path = "pkg/tool/link.dart"))
    asserts.true(env, err != None and "`pkg/hook/link.dart`" in err, err)
    return unittest.end(env)

_link_hook_location_test = unittest.make(_link_hook_location_test_impl)

# --- pub spokes ---

def _classify_pub_hooks_test_impl(ctx):
    # A link hook is runnable, so it never makes a package fail; only an
    # unhandled build hook does.
    env = unittest.begin(ctx)
    link_only = classify_pub_hooks(has_build_hook = False, has_link_hook = True, build_hook_handled = False)
    asserts.equals(env, "", link_only.unreplaced_hook)
    asserts.equals(env, "hook/link.dart", link_only.link_hook)

    both = classify_pub_hooks(has_build_hook = True, has_link_hook = True, build_hook_handled = False)
    asserts.equals(env, "hook/build.dart", both.unreplaced_hook)
    asserts.equals(env, "hook/link.dart", both.link_hook)

    handled = classify_pub_hooks(has_build_hook = True, has_link_hook = True, build_hook_handled = True)
    asserts.equals(env, "", handled.unreplaced_hook)
    asserts.equals(env, "hook/link.dart", handled.link_hook)

    none = classify_pub_hooks(has_build_hook = False, has_link_hook = False, build_hook_handled = False)
    asserts.equals(env, "", none.unreplaced_hook)
    asserts.equals(env, "", none.link_hook)
    return unittest.end(env)

_classify_pub_hooks_test = unittest.make(_classify_pub_hooks_test_impl)

def _spoke_states_link_hook_test_impl(ctx):
    env = unittest.begin(ctx)
    with_hook = make_dart_library_build_content("glyphs", [], "3.13", link_hook = "hook/link.dart")
    asserts.true(env, '    link_hook = "hook/link.dart",\n' in with_hook, with_hook)
    without = make_dart_library_build_content("glyphs", [], "3.13")
    asserts.true(env, "link_hook" not in without, without)
    return unittest.end(env)

_spoke_states_link_hook_test = unittest.make(_spoke_states_link_hook_test_impl)

# --- merge_package_records ---

def _merge_adopts_link_hook_test_impl(ctx):
    # A package split across targets may carry its hook on any of them; the
    # merged record keeps it whichever comes first.
    env = unittest.begin(ctx)
    merged = merge_package_records([
        struct(package_name = "p", lib_root = "a", link_hook = None),
        struct(package_name = "p", lib_root = "b", link_hook = "b/hook/link.dart"),
    ])
    asserts.equals(env, 1, len(merged))
    asserts.equals(env, "a", merged[0].lib_root)
    asserts.equals(env, "b/hook/link.dart", package_link_hook(merged[0]))

    kept = merge_package_records([
        struct(package_name = "p", lib_root = "a", link_hook = "a/hook/link.dart"),
        struct(package_name = "p", lib_root = "b", link_hook = "b/hook/link.dart"),
    ])
    asserts.equals(env, "a/hook/link.dart", package_link_hook(kept[0]))
    return unittest.end(env)

_merge_adopts_link_hook_test = unittest.make(_merge_adopts_link_hook_test_impl)

# --- analysis tests ---

def _actions(env, mnemonic):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _recording_binary_test_impl(ctx):
    # The compile action itself records: its argv carries the flag and its
    # outputs the file the provider names.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[DartRecordedUsesInfo]
    asserts.equals(env, "aot", info.kind)
    asserts.equals(env, target.label.name + ".recorded_uses.json", info.file.basename)
    compiles = _actions(env, "DartCompile")
    asserts.equals(env, 1, len(compiles))
    asserts.true(
        env,
        "--recorded-uses=" + info.file.path in compiles[0].argv,
        "missing --recorded-uses: %s" % compiles[0].argv,
    )
    asserts.true(env, info.file in compiles[0].outputs.to_list())
    return analysistest.end(env)

recording_binary_test = analysistest.make(_recording_binary_test_impl)

def _empty_recording_binary_test_impl(ctx):
    # A kernel is not tree-shaken: nothing records, the file is `{}`.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[DartRecordedUsesInfo]
    asserts.equals(env, "empty", info.kind)
    for compile in _actions(env, "DartCompile"):
        asserts.false(
            env,
            [a for a in compile.argv if a.startswith("--recorded-uses")],
            "a kernel compile must not be asked to record: %s" % compile.argv,
        )
    writes = [a for a in _actions(env, "FileWrite") if info.file in a.outputs.to_list()]
    asserts.equals(env, 1, len(writes))
    asserts.equals(env, "{}", writes[0].content)
    return analysistest.end(env)

empty_recording_binary_test = analysistest.make(_empty_recording_binary_test_impl)

def _not_recording_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.false(env, DartRecordedUsesInfo in target)
    for compile in _actions(env, "DartCompile"):
        asserts.false(env, [a for a in compile.argv if a.startswith("--recorded-uses")])
    return analysistest.end(env)

not_recording_binary_test = analysistest.make(_not_recording_binary_test_impl)

def _library_records_link_hook_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartInfo]
    hooks = [
        package_link_hook(p)
        for p in info.transitive_packages.to_list()
        if p.package_name == ctx.attr.package_name
    ]
    asserts.equals(env, 1, len(hooks))
    asserts.true(env, hooks[0] != None and hooks[0].short_path.endswith("/hook/link.dart"), str(hooks))
    return analysistest.end(env)

library_records_link_hook_test = analysistest.make(
    _library_records_link_hook_test_impl,
    attrs = {"package_name": attr.string()},
)

def _link_hook_actions_test_impl(ctx):
    # One action for the one package with a hook; the dependency without one
    # gets none. The declared asset is that action's output, named by id.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runs = _actions(env, "DartLinkHook")
    asserts.equals(env, 1, len(runs))
    argv = runs[0].argv
    asserts.true(env, "--package-name" in argv and argv[argv.index("--package-name") + 1] == "link_hook_fixture", str(argv))
    asserts.true(env, argv[argv.index("--package-root") + 1].endswith("dart/tests/link_hook_fixture"), str(argv))

    assets = target[DartDataAssetInfo].assets.to_list()
    asserts.equals(env, ["package:link_hook_fixture/data/index.json"], [a.id for a in assets])
    asserts.equals(env, "link_hook_fixture", assets[0].package)
    asserts.equals(env, "data/index.json", assets[0].name)
    asserts.true(env, assets[0].file.short_path.endswith(target.label.name + "/link_hook_fixture/data/index.json"))
    asserts.true(env, assets[0].file in runs[0].outputs.to_list())
    asserts.true(env, "data/index.json=" + assets[0].file.path in argv, str(argv))
    asserts.equals(env, [assets[0].file], target[DefaultInfo].files.to_list())

    recorded = ctx.attr.recorded_uses_basename
    inputs = [f.basename for f in runs[0].inputs.to_list()]
    asserts.true(env, recorded in inputs, "%s not among inputs" % recorded)
    asserts.true(env, "link.dart" in inputs)
    return analysistest.end(env)

link_hook_actions_test = analysistest.make(
    _link_hook_actions_test_impl,
    attrs = {"recorded_uses_basename": attr.string()},
)

def _validation_runs_assetless_hook_test_impl(ctx):
    # A hook whose package declares no assets still runs, as a validation
    # output, so its verdict on the program's uses is never skipped.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runs = _actions(env, "DartLinkHook")
    asserts.equals(env, 1, len(runs))
    validation = target[OutputGroupInfo]._validation.to_list()
    asserts.equals(env, runs[0].outputs.to_list(), validation)
    asserts.equals(env, [], target[DefaultInfo].files.to_list())
    return analysistest.end(env)

validation_runs_assetless_hook_test = analysistest.make(_validation_runs_assetless_hook_test_impl)

def _expect_failure(msg):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(env, msg)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

asset_without_hook_test = _expect_failure("which has no link hook in `deps`")
malformed_asset_id_test = _expect_failure("is not of the form `package:<package>/<name>`")
recorded_uses_not_json_test = _expect_failure("must provide `DartRecordedUsesInfo`")
misplaced_link_hook_test = _expect_failure("`link_hook` must be the package's `hook/link.dart`")

def link_hook_test_suite(name):
    """Registers the pure-helper unit tests.

    The analysis tests are declared beside their fixtures, in
    `//dart/tests/link_hook_fixture`.

    Args:
      name: Aggregating `test_suite` target name.
    """
    small_unittest_suite(
        name,
        _kind_by_mode_test,
        _parses_ids_test,
        _rejects_malformed_ids_test,
        _rejects_duplicate_ids_test,
        _recorded_uses_file_test,
        _package_root_test,
        _link_hook_location_test,
        _classify_pub_hooks_test,
        _spoke_states_link_hook_test,
        _merge_adopts_link_hook_test,
    )
