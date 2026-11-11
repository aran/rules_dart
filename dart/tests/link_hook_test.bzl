"""Tests for recorded uses and link hooks.

`dart_binary(record_use = True)` has two shapes — the compiler records in the
modes that tree-shake, and an empty file stands in for the others — and each
compile pipeline (direct, and with a native-assets mapping for code assets) must carry the
flag to the one action that records. A linked `dart_program_assets` runs one
action per package with a hook, declares a File for each id the
`link_hook_assets` of the package's `dart_package_metadata` promise, and a
directory for the rest; an unlinked one runs none. Every `fail()` it can raise is a message a user reads, so each
has a case asserting what it says.

The pure helpers are unit tests; the rule shapes are `analysistest`s over
`//dart/tests/link_hook_fixture`, where nothing is ever built.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartInfo", "DartPackageInfo", "DartProgramAssetsInfo", "DartRecordedUsesInfo")
load("//dart/private:common.bzl", "merge_package_records", "package_link_hook")
load("//dart/private:dart_compile.bzl", "recorded_uses_kind")
load("//dart/private:dart_package_metadata.bzl", "link_hook_error")
load("//dart/private:package_info.bzl", "link_hook_assets_error", "parse_data_asset_ids")
load("//dart/private:program_assets.bzl", "package_files_error", "program_asset_file", "recorded_uses_file_error")

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

# --- package_files_error ---

def _package_files_test_impl(ctx):
    # A program's own files reach its package's hook only from that
    # package's `lib/`, and only with the package they belong to.
    env = unittest.begin(ctx)
    pkg = DartPackageInfo(None, package_name = "app", package_root = "app", language_version = "")
    lib = struct(short_path = "app/lib/a.dart")
    asserts.equals(env, None, package_files_error("//a:b", pkg, [lib]))
    asserts.equals(env, None, package_files_error("//a:b", None, []))
    err = package_files_error("//a:b", pkg, [struct(short_path = "app/bin/main.dart")])
    asserts.true(env, err != None and "are not under `app/lib/`" in err, err)
    err = package_files_error("//a:b", None, [lib])
    asserts.true(env, err != None and "for a program in no package" in err, err)
    return unittest.end(env)

_package_files_test = unittest.make(_package_files_test_impl)

# --- link_hook_error ---

def _link_hook_location_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, link_hook_error("//a:b", "pkg", None))
    asserts.equals(env, None, link_hook_error("//a:b", "pkg", struct(short_path = "pkg/hook/link.dart")))
    asserts.equals(env, None, link_hook_error("//a:b", "", struct(short_path = "hook/link.dart")))
    err = link_hook_error("//a:b", "pkg", struct(short_path = "pkg/tool/link.dart"))
    asserts.true(env, err != None and "`pkg/hook/link.dart`" in err, err)
    return unittest.end(env)

_link_hook_location_test = unittest.make(_link_hook_location_test_impl)

# --- link_hook_assets_error ---

def _link_hook_assets_test_impl(ctx):
    # What a package's hook emits is the package's own, stated beside its hook.
    env = unittest.begin(ctx)
    hook = struct(short_path = "pkg/hook/link.dart")
    asserts.equals(env, None, link_hook_assets_error("//a:b", "pkg", hook, ["package:pkg/glyphs/index.json"]))
    asserts.equals(env, None, link_hook_assets_error("//a:b", "pkg", hook, []))
    asserts.equals(env, None, link_hook_assets_error("//a:b", "pkg", None, []))
    for ids, hook_file, part in [
        (["package:pkg/index.json"], None, "which has no `link_hook`"),
        (["package:other/index.json"], hook, "is not namespaced to this package"),
        (["pkg/index.json"], hook, "is not of the form `package:<package>/<name>`"),
        (["package:pkg/a.json", "package:pkg/a.json"], hook, "declared twice"),
    ]:
        err = link_hook_assets_error("//a:b", "pkg", hook_file, ids)
        asserts.true(env, err != None and part in err, "%s: %s" % (ids, err))
    return unittest.end(env)

_link_hook_assets_test = unittest.make(_link_hook_assets_test_impl)

def _record_checks_link_hook_assets_test_impl(ctx):
    # A rule author's record states them as a declaration does.
    env = unittest.begin(ctx)
    hook = struct(short_path = "pkg/hook/link.dart")
    pkg = DartPackageInfo(None, package_name = "pkg", package_root = "pkg", language_version = "", link_hook = hook, link_hook_assets = ["package:pkg/index.json"])
    asserts.equals(env, ("package:pkg/index.json",), pkg.link_hook_assets)
    asserts.equals(env, (), DartPackageInfo(None, package_name = "pkg", package_root = "pkg", language_version = "").link_hook_assets)
    return unittest.end(env)

_record_checks_link_hook_assets_test = unittest.make(_record_checks_link_hook_assets_test_impl)

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

    # A `pub.package()` spoke states its build hook, which its code assets
    # (curated ones) replace.
    built = make_dart_library_build_content("glyphs", [], "3.13", code_assets = ["//a:asset"], build_hook = "hook/build.dart")
    asserts.true(env, '    build_hook = "hook/build.dart",\n' in built, built)
    asserts.true(env, "build_hook" not in without, without)
    return unittest.end(env)

_spoke_states_link_hook_test = unittest.make(_spoke_states_link_hook_test_impl)

# --- merge_package_records ---

def _merge_adopts_link_hook_test_impl(ctx):
    # A package split across targets may carry its hook on any of them; the
    # merged record keeps it whichever comes first.
    env = unittest.begin(ctx)
    hook = struct(short_path = "b/hook/link.dart")
    merged = merge_package_records([
        DartPackageInfo(None, package_name = "p", package_root = "a", link_hook = None, language_version = ""),
        DartPackageInfo(None, package_name = "p", package_root = "b", link_hook = hook, language_version = ""),
    ])
    asserts.equals(env, 1, len(merged))
    asserts.equals(env, "a", merged[0].package_root)
    asserts.equals(env, hook, package_link_hook(merged[0]))

    # Two hubs supplying one package name one hook in two places: they agree,
    # and the first record's File is kept. Two different hooks are an error;
    # see `package_record_test`.
    first = struct(short_path = "a/hook/link.dart")
    kept = merge_package_records([
        DartPackageInfo(None, package_name = "p", package_root = "a", link_hook = first, language_version = ""),
        DartPackageInfo(None, package_name = "p", package_root = "b", link_hook = struct(short_path = "b/hook/link.dart"), language_version = ""),
    ])
    asserts.equals(env, first, package_link_hook(kept[0]))
    return unittest.end(env)

_merge_adopts_link_hook_test = unittest.make(_merge_adopts_link_hook_test_impl)

# --- analysis tests ---

def _actions(env, mnemonic):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _has_path_arg(argv, prefix, file):
    # The output directory in an argument is the mapped one when the build maps
    # output paths (`--experimental_output_paths=strip`), so only the part
    # under it is compared.
    return [a for a in argv if a.startswith(prefix + "bazel-out/") and a.endswith("/" + file.short_path)] != []

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
        _has_path_arg(compiles[0].argv, "--recorded-uses=", info.file),
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
    # gets none. The promised asset is that action's output, known by id; what
    # else the hook emits lands in the package's output directory.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runs = _actions(env, "DartLinkHook")
    asserts.equals(env, 1, len(runs))
    argv = runs[0].argv
    asserts.true(env, "--package-name" in argv and argv[argv.index("--package-name") + 1] == "link_hook_fixture", str(argv))

    # The declaration stating its `link_hook_assets`, for the runner's errors.
    asserts.true(env, "--metadata" in argv and argv[argv.index("--metadata") + 1] == "@@//dart/tests/link_hook_fixture:pubspec-metadata", str(argv))

    # The hook runs from its package assembled into one directory, not from
    # the package's own source directory, and is found in it.
    tree = target.label.name + ".pkgs/link_hook_fixture"
    asserts.true(env, argv[argv.index("--package-root") + 1].endswith(tree), str(argv))
    asserts.false(env, "--hook" in argv, str(argv))

    info = target[DartProgramAssetsInfo]
    index = info.known["package:link_hook_fixture/data/index.json"]
    asserts.true(env, index.short_path.endswith(target.label.name + "/link_hook_fixture/data/index.json"))
    asserts.true(env, index in runs[0].outputs.to_list())
    asserts.true(env, _has_path_arg(argv, "data/index.json=", index), str(argv))
    directory = [f for f in runs[0].outputs.to_list() if f.is_directory]
    asserts.equals(env, 1, len(directory), str(runs[0].outputs.to_list()))
    asserts.true(env, directory[0].short_path.endswith(target.label.name + "/link_hook_fixture.data"))
    asserts.true(env, _has_path_arg(argv, "", directory[0]), str(argv))
    files = info.files.to_list()
    asserts.true(env, index in files and directory[0] in files, str(files))
    asserts.true(env, info.manifest in target[DefaultInfo].files.to_list())

    # The manifest is merged from each hook's record.
    merges = _actions(env, "DartProgramAssets")
    asserts.equals(env, 1, len(merges))
    asserts.equals(env, [info.manifest], merges[0].outputs.to_list())
    records = [f for f in runs[0].outputs.to_list() if f.basename == "link_hook_fixture.link_output.json"]
    asserts.equals(env, 1, len(records))
    asserts.true(env, records[0] in merges[0].inputs.to_list())

    recorded = ctx.attr.recorded_uses_basename
    inputs = runs[0].inputs.to_list()
    basenames = [f.basename for f in inputs]
    asserts.true(env, recorded in basenames, "%s not among inputs" % recorded)

    # The package arrives as that tree alone: neither the hook nor any other of
    # its files is an input of its own, so none is there but through the tree.
    trees = [f for f in inputs if f.path.endswith(tree)]
    asserts.equals(env, 1, len(trees), str(inputs))
    asserts.true(env, trees[0].is_directory)
    asserts.false(env, "link.dart" in basenames, str(basenames))
    asserts.false(env, "fixture.dart" in basenames, str(basenames))
    return analysistest.end(env)

link_hook_actions_test = analysistest.make(
    _link_hook_actions_test_impl,
    attrs = {"recorded_uses_basename": attr.string()},
)

def _link_hook_data_assets_test_impl(ctx):
    # The hook's package's declared asset is the hook's input, by name, and
    # not shipped itself: the hook decides. The declared asset of the package
    # without a hook ships as it is, beside what the hook emits, and is known.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runs = _actions(env, "DartLinkHook")
    asserts.equals(env, 1, len(runs))
    argv = runs[0].argv
    raw = [f for f in runs[0].inputs.to_list() if f.short_path == "dart/tests/link_hook_fixture/raw.json"]
    asserts.equals(env, 1, len(raw), str(runs[0].inputs.to_list()))
    asserts.true(env, "data/raw.json=" + raw[0].path in argv, str(argv))
    asserts.equals(env, 1, len([a for a in argv if a == "--input-data-asset"]), str(argv))

    info = target[DartProgramAssetsInfo]
    asserts.equals(
        env,
        sorted(["package:plain_data/banner.txt", "package:link_hook_fixture/data/index.json"]),
        sorted(info.known.keys()),
    )
    banner = info.known["package:plain_data/banner.txt"]
    asserts.equals(env, "dart/tests/link_hook_fixture/plain_data/banner.txt", banner.short_path)
    asserts.true(env, banner in info.files.to_list())
    asserts.false(env, raw[0] in info.files.to_list())

    # The banner's entry is written now, for the manifest step to merge.
    plan = [a for a in _actions(env, "FileWrite") if a.outputs.to_list()[0].basename.endswith(".assets_plan.json")]
    asserts.equals(env, 1, len(plan))
    content = json.decode(plan[0].content)
    asserts.equals(
        env,
        [{"type": "data_assets/data", "encoding": {"package": "plain_data", "name": "banner.txt", "file": banner.path}}],
        content["assets"],
    )
    asserts.equals(env, ["link_hook_fixture"], content["packages"].keys())
    return analysistest.end(env)

link_hook_data_assets_test = analysistest.make(_link_hook_data_assets_test_impl)

def _link_hook_code_assets_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runs = _actions(env, "DartLinkHook")
    asserts.equals(env, 1, len(runs))
    argv = runs[0].argv
    library = [f for f in runs[0].inputs.to_list() if f.basename.startswith("libempty_shared.") or f.basename == "empty_shared.dll"]
    asserts.equals(env, 1, len(library), str(runs[0].inputs.to_list()))
    asserts.true(
        env,
        "package:link_hook_coded/native=dynamic_loading_bundle=" + library[0].path in argv,
        str(argv),
    )
    config = json.decode(argv[argv.index("--code-config") + 1])
    asserts.equals(env, "dynamic", config["link_mode_preference"])
    asserts.true(env, config["target_os"] in ["linux", "macos", "windows"], str(config))

    info = target[DartProgramAssetsInfo]
    asserts.equals(env, {}, info.known)
    asserts.true(env, library[0] in info.files.to_list())
    plan = [a for a in _actions(env, "FileWrite") if a.outputs.to_list()[0].basename.endswith(".assets_plan.json")]
    inputs = json.decode(plan[0].content)["packages"]["link_hook_coded"]["code_inputs"]
    asserts.equals(
        env,
        {"package:link_hook_coded/native": {"id": "package:link_hook_coded/native", "link_mode": {"type": "dynamic_loading_bundle"}, "file": library[0].path}},
        inputs,
    )
    return analysistest.end(env)

link_hook_code_assets_test = analysistest.make(_link_hook_code_assets_test_impl)

def _unlinked_assets_test_impl(ctx):
    # Not linked, no hook runs, every declared asset ships, and the manifest
    # is written at analysis time with all of them, known.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, [], _actions(env, "DartLinkHook"))
    asserts.equals(env, [], _actions(env, "DartProgramAssets"))
    info = target[DartProgramAssetsInfo]
    asserts.equals(
        env,
        sorted(["package:plain_data/banner.txt", "package:link_hook_fixture/data/raw.json"]),
        sorted(info.known.keys()),
    )
    writes = [a for a in _actions(env, "FileWrite") if info.manifest in a.outputs.to_list()]
    asserts.equals(env, 1, len(writes))
    content = json.decode(writes[0].content)
    asserts.equals(
        env,
        ["data/raw.json", "banner.txt"],
        [entry["encoding"]["name"] for entry in content["assets"]],
    )
    asserts.equals(
        env,
        sorted([f.short_path for f in info.known.values()]),
        sorted([f.short_path for f in info.files.to_list()]),
    )
    return analysistest.end(env)

unlinked_assets_test = analysistest.make(_unlinked_assets_test_impl)

def _validation_runs_assetless_hook_test_impl(ctx):
    # A hook whose package promises no `link_hook_assets` still runs, as the
    # manifest is a validation output, so its verdict on the program's uses is
    # never skipped.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runs = _actions(env, "DartLinkHook")
    asserts.equals(env, 1, len(runs))
    info = target[DartProgramAssetsInfo]

    # Beside it, Bazel carries its libraries' own validations (their import
    # checks) into the group.
    validation = target[OutputGroupInfo]._validation.to_list()
    asserts.true(env, info.manifest in validation, str(validation))
    asserts.equals(env, {}, info.known)
    return analysistest.end(env)

validation_runs_assetless_hook_test = analysistest.make(_validation_runs_assetless_hook_test_impl)

def _known_asset_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    asserts.true(env, files[0].short_path.endswith("/link_hook_fixture/data/index.json"), str(files))
    return analysistest.end(env)

known_asset_test = analysistest.make(_known_asset_test_impl)

def _known_asset_impl(ctx):
    return [DefaultInfo(files = depset([program_asset_file(ctx.attr.assets[DartProgramAssetsInfo], ctx.attr.asset_id)]))]

known_asset = rule(
    implementation = _known_asset_impl,
    attrs = {
        "asset_id": attr.string(),
        "assets": attr.label(providers = [DartProgramAssetsInfo]),
    },
)

def _expect_failure(msg):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(env, msg)
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

link_hook_assets_without_hook_test = _expect_failure("`link_hook_assets` [\"package:link_hook_hookless/index.json\"] are stated for package `link_hook_hookless`, which has no `link_hook`")
unknown_asset_test = _expect_failure("`package:link_hook_fixture/data/raw.json` is not an asset this program is known to ship before it is built. Either no package of the program declares it, or package `link_hook_fixture` has a link hook, which decides when it runs whether it ships. To name it here, list it in the `link_hook_assets` of `link_hook_fixture`'s `dart_package_metadata`")
own_package_not_named_test = _expect_failure("is the uses of a program in the package declared by `@@//dart/tests/link_hook_fixture:pubspec-metadata`, but `package` names none")
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
        _package_files_test,
        _link_hook_location_test,
        _link_hook_assets_test,
        _record_checks_link_hook_assets_test,
        _classify_pub_hooks_test,
        _spoke_states_link_hook_test,
        _merge_adopts_link_hook_test,
    )
