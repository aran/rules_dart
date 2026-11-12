"""Tests for recorded uses and link hooks.

`dart_binary(record_use = True)` has two shapes — the compiler records in the
modes that tree-shake, and an empty file stands in for the others — and each
compile pipeline (direct, and with a native-assets mapping for code assets) must carry the
flag to the one action that records. A linked `dart_program_assets` runs one
action per package with a hook, declares a File for each id the
`link_hook_assets` of the package's `dart_package_metadata` promise, a
directory for the rest and, with code assets to choose among, a file of the
ids it keeps; an unlinked one runs none. `program_assets_action_args()` hands
it all to an action in one param file. Every `fail()` it can raise is a message a user reads, so each
has a case asserting what it says.

The pure helpers are unit tests; the rule shapes are `analysistest`s over
`//dart/tests/link_hook_fixture`, where nothing is ever built.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartInfo", "DartPackageInfo", "DartProgramAssetsInfo", "DartRecordedUsesInfo")
load("//dart/private:common.bzl", "merge_package_records", "package_link_hook")
load("//dart/private:dart_compile.bzl", "recorded_uses_kind")
load("//dart/private:dart_package_metadata.bzl", "link_hook_error")
load("//dart/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//dart/private:package_info.bzl", "link_hook_assets_error", "parse_data_asset_ids")
load("//dart/private:program_assets.bzl", "PROGRAM_ASSETS_FORMAT", "PROGRAM_ASSETS_TOOLCHAINS", "dart_program_assets_actions", "package_files_error", "program_asset_file", "program_assets_action_args", "program_assets_attrs", "program_kernel_code_assets", "recorded_uses_file_error")

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
    index = info.data_assets["package:link_hook_fixture/data/index.json"]
    asserts.true(env, index.short_path.endswith(target.label.name + "/link_hook_fixture/data/index.json"))
    asserts.true(env, index in runs[0].outputs.to_list())
    asserts.true(env, _has_path_arg(argv, "data/index.json=", index), str(argv))
    directory = [f for f in runs[0].outputs.to_list() if f.is_directory]
    asserts.equals(env, 1, len(directory), str(runs[0].outputs.to_list()))
    asserts.true(env, directory[0].short_path.endswith(target.label.name + "/link_hook_fixture.data"))
    asserts.true(env, _has_path_arg(argv, "", directory[0]), str(argv))

    # What the hook emits is its package's one link output: the directory,
    # and no selection, as it has no code assets to choose among. The
    # promised file is a data asset that ships, and not in the directory.
    asserts.equals(env, 1, len(info.link_outputs))
    output = info.link_outputs[0]
    asserts.equals(env, "link_hook_fixture", output.package)
    asserts.equals(env, directory[0], output.data_assets)
    asserts.equals(env, {}, output.code_assets)
    asserts.equals(env, None, output.code_selection)
    asserts.false(env, "--code-selection" in argv, str(argv))
    asserts.equals(env, sorted([index.path, directory[0].path]), sorted([f.path for f in runs[0].outputs.to_list()]))

    # No action beyond the hook's: nothing merges what it emits.
    asserts.equals(env, [], _actions(env, "DartProgramAssets"))

    # The target's output lists the assets for its runfiles, which hold them.
    listing = target[DefaultInfo].files.to_list()
    asserts.equals(env, [target.label.name + ".program_assets"], [f.basename for f in listing])
    runfiles = target[DefaultInfo].default_runfiles.files.to_list()
    asserts.true(env, index in runfiles and directory[0] in runfiles and listing[0] in runfiles, str(runfiles))
    writes = [a for a in _actions(env, "FileWrite") if listing[0] in a.outputs.to_list()]
    asserts.equals(env, 1, len(writes))
    asserts.true(env, writes[0].content.startswith("--format\n%s\n--paths\nrunfiles\n--holds\ndata code\n" % PROGRAM_ASSETS_FORMAT), writes[0].content)
    asserts.true(env, ("--link-data\nlink_hook_fixture\n_main/" + directory[0].short_path + "\n") in writes[0].content, writes[0].content)
    asserts.false(env, "--link-code" in writes[0].content, writes[0].content)
    asserts.false(env, "bazel-out/" in writes[0].content, writes[0].content)

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
        sorted(info.data_assets.keys()),
    )
    banner = info.data_assets["package:plain_data/banner.txt"]
    asserts.equals(env, "dart/tests/link_hook_fixture/plain_data/banner.txt", banner.short_path)
    asserts.equals(env, ["link_hook_fixture"], [o.package for o in info.link_outputs])
    runfiles = target[DefaultInfo].default_runfiles.files.to_list()
    asserts.true(env, banner in runfiles, str(runfiles))
    asserts.false(env, raw[0] in runfiles, str(runfiles))
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

    # The library is a candidate of the hook's link output, not a code asset
    # that certainly ships; the hook writes the ids it keeps to its selection.
    info = target[DartProgramAssetsInfo]
    asserts.equals(env, {}, info.code_assets)
    asserts.equals(env, 1, len(info.link_outputs))
    output = info.link_outputs[0]
    asserts.equals(env, ["package:link_hook_coded/native"], output.code_assets.keys())
    asserts.equals(env, library[0], output.code_assets["package:link_hook_coded/native"].file)
    asserts.equals(env, "link_hook_coded.code_selection", output.code_selection.basename)
    asserts.true(env, output.code_selection in runs[0].outputs.to_list())
    asserts.true(env, _has_path_arg(argv, "", output.code_selection), str(argv))

    # A kernel of the program maps every id it can load, the candidates too.
    asserts.equals(env, ["package:link_hook_coded/native"], [a.asset_id for a in program_kernel_code_assets(info)])
    return analysistest.end(env)

link_hook_code_assets_test = analysistest.make(_link_hook_code_assets_test_impl)

def _native_link_test_impl(ctx):
    # The package's tool maps the program's uses to symbols, which become the
    # linker's export list; the library is the program's own, and known.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[DartProgramAssetsInfo]
    library = info.code_assets["package:link_hook_native/native"].file
    asserts.true(env, library.basename in ["libnative.so", "libnative.dylib", "native.dll"], library.basename)
    asserts.true(env, library.short_path.startswith("dart/tests/link_hook_fixture/%s/link_hook_native/" % target.label.name), library.short_path)
    links = [a for a in analysistest.target_actions(env) if library in a.outputs.to_list()]
    asserts.equals(env, 1, len(links))
    symbols = _actions(env, "DartLinkSymbols")
    exports = _actions(env, "DartLinkExports")
    if not ctx.attr.linked:
        asserts.equals(env, [], symbols)
        asserts.equals(env, [], exports)

        # A DLL exports nothing, and the linker writes no import library,
        # unless a module-definition file lists what it exports: all of it.
        all_exports = _actions(env, "DefParser")
        if library.extension == "dll":
            asserts.equals(env, 1, len(all_exports))
            asserts.true(env, all_exports[0].outputs.to_list()[0] in links[0].inputs.to_list(), str(links[0].inputs.to_list()))
        else:
            asserts.equals(env, [], all_exports)
        return analysistest.end(env)
    asserts.equals(env, 1, len(symbols))
    uses = [f for f in symbols[0].inputs.to_list() if f.basename == "uses.json"]
    asserts.equals(env, 1, len(uses))
    asserts.equals(env, uses[0].path, symbols[0].argv[1])
    asserts.true(env, symbols[0].argv[2].endswith("link_hook_native/native.symbols"), str(symbols[0].argv))
    asserts.equals(env, 1, len(exports))
    argv = exports[0].argv
    script = exports[0].outputs.to_list()[0]
    asserts.true(env, argv[argv.index("--format") + 1] in ["elf", "macho", "def"], str(argv))
    asserts.true(env, script in links[0].inputs.to_list(), str(links[0].inputs.to_list()))
    return analysistest.end(env)

native_link_test = analysistest.make(_native_link_test_impl, attrs = {"linked": attr.bool()})

def _without_cpp_impl(ctx):
    result = dart_program_assets_actions(ctx, package = None, deps = ctx.attr.deps, name = ctx.label.name)
    return [result.info]

assets_without_cpp = rule(
    implementation = _without_cpp_impl,
    attrs = {"deps": attr.label_list(providers = [DartInfo])} | program_assets_attrs(),
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = PROGRAM_ASSETS_TOOLCHAINS,
)

def _unlinked_assets_test_impl(ctx):
    # Not linked, no hook runs, and every declared asset ships, known.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, [], _actions(env, "DartLinkHook"))
    info = target[DartProgramAssetsInfo]
    asserts.equals(
        env,
        sorted(["package:plain_data/banner.txt", "package:link_hook_fixture/data/raw.json"]),
        sorted(info.data_assets.keys()),
    )
    asserts.equals(env, {}, info.code_assets)
    asserts.equals(env, (), info.link_outputs)
    return analysistest.end(env)

unlinked_assets_test = analysistest.make(_unlinked_assets_test_impl)

def _validation_runs_assetless_hook_test_impl(ctx):
    # A hook whose package promises no `link_hook_assets` still runs, as its
    # output directory is a validation output, so its verdict on the
    # program's uses is never skipped.
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    runs = _actions(env, "DartLinkHook")
    asserts.equals(env, 1, len(runs))
    info = target[DartProgramAssetsInfo]

    # Beside it, Bazel carries its libraries' own validations (their import
    # checks) into the group.
    validation = target[OutputGroupInfo]._validation.to_list()
    asserts.true(env, info.link_outputs[0].data_assets in validation, str(validation))
    asserts.equals(env, {}, info.data_assets)
    return analysistest.end(env)

validation_runs_assetless_hook_test = analysistest.make(_validation_runs_assetless_hook_test_impl)

def _read_assets_impl(ctx):
    code = ctx.attr.code if ctx.attr.code != "none" else None
    a = program_assets_action_args(ctx.actions, ctx.attr.assets[DartProgramAssetsInfo], data = ctx.attr.data, code = code)
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run_shell(
        outputs = [out],
        inputs = a.inputs,
        arguments = [a.args],
        command = "touch " + out.path,
        mnemonic = "ReadProgramAssets",
    )
    return [DefaultInfo(files = depset([out]))]

read_assets = rule(
    implementation = _read_assets_impl,
    attrs = {
        "assets": attr.label(providers = [DartProgramAssetsInfo]),
        "code": attr.string(default = "libraries"),
        "data": attr.bool(default = True),
    },
)

def _assets_action_args_test_impl(ctx):
    # The tool gets one flag naming one param file, which holds what the
    # action reads of the program's assets in the line format: each certain
    # one by id, each hook's output directory, and its selection and
    # candidates, with every File's path as Bazel maps it. Every File it
    # names is an input, and no other asset's file is.
    env = analysistest.begin(ctx)
    reads = _actions(env, "ReadProgramAssets")
    asserts.equals(env, 1, len(reads))
    info = ctx.attr.assets[DartProgramAssetsInfo]
    output = info.link_outputs[0]
    data = ctx.attr.data
    code = ctx.attr.code if ctx.attr.code != "none" else None
    holds = (["data"] if data else []) + ({"libraries": ["code"], "names": ["code-names"]}.get(code, []))
    expected = ["--format", PROGRAM_ASSETS_FORMAT, "--paths", "exec", "--holds", " ".join(holds)]
    wanted = []
    libraries = []
    if data:
        for asset_id in sorted(info.data_assets.keys()):
            expected.extend(["--data-asset", asset_id, info.data_assets[asset_id].path])
            wanted.append(info.data_assets[asset_id])
        expected.extend(["--link-data", output.package, output.data_assets.path])
        wanted.append(output.data_assets)
    if code != None and output.code_selection != None:
        expected.extend(["--link-code", output.package, output.code_selection.path])
        wanted.append(output.code_selection)
        for asset_id in sorted(output.code_assets.keys()):
            library = output.code_assets[asset_id].file
            libraries.append(library)
            expected.extend(["--candidate", asset_id, "dynamic_loading_bundle", library.path if code == "libraries" else library.basename, ""])
    if code == "libraries":
        wanted.extend(libraries)
    argv = reads[0].argv

    # Analysis shows a param file's lines in place of its flag.
    asserts.equals(env, expected, argv[argv.index("--format"):])
    asserts.equals(env, ctx.attr.expected_data, sorted(info.data_assets.keys()))
    asserts.equals(env, ctx.attr.expected_candidates, sorted(output.code_assets.keys()))
    inputs = reads[0].inputs.to_list()
    asserts.equals(env, sorted([f.path for f in wanted]), sorted([f.path for f in inputs]))
    if data and code == "libraries":
        for f in ctx.attr.assets[DefaultInfo].default_runfiles.files.to_list():
            if f.basename != ctx.attr.assets.label.name + ".program_assets":
                asserts.true(env, f in inputs, "%s is not an input" % f.short_path)
    return analysistest.end(env)

assets_action_args_test = analysistest.make(
    _assets_action_args_test_impl,
    attrs = {
        "assets": attr.label(providers = [DartProgramAssetsInfo]),
        "code": attr.string(default = "libraries"),
        "data": attr.bool(default = True),
        "expected_candidates": attr.string_list(),
        "expected_data": attr.string_list(),
    },
)

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
without_cpp_test = _expect_failure("assets_without_cpp has to declare 'cpp' as a required fragment")
own_package_not_named_test = _expect_failure("is the uses of a program in the package declared by `@@//dart/tests/link_hook_fixture:pubspec-metadata`, but `package` names none")
recorded_uses_not_json_test = _expect_failure("must provide `DartRecordedUsesInfo`")
nothing_read_test = _expect_failure("A tool handed a program's assets reads some of them: `data = True`, a `code` view, or both.")
unknown_code_view_test = _expect_failure("`code` is one of [\"libraries\", \"names\"], or None for no code assets; got \"bytes\".")
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
