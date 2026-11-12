"""The SDK file sets: what each holds on the pinned SDK, and copies of them.

`sdk_file_sets_test` pins each set of the resolved toolchain's SDK, by path
under the SDK root with Windows' `.exe` dropped, so that a pattern which stops
matching on a new SDK (a renamed snapshot, say) fails here rather than leaving
an action short of a file. Whether a set is enough for its use is
`sdk_files_test`'s question: it runs each use against `sdk_file_set_copy`, a
directory holding copies of that set's files only.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart:toolchain.bzl", "SDK_FILE_SETS")

_TOOLCHAIN = Label("//dart:toolchain_type")

_DART = ["bin/dart"]
_DARTVM = ["bin/dartvm"]
_DARTAOTRUNTIME = ["bin/dartaotruntime"]
_DARTDEV = ["bin/snapshots/dartdev_aot.dart.snapshot"]
_ANALYZER_SDK = ["lib/_internal/allowed_experiments.json", "version"]

# Every set's files on the pinned SDK. `analyze` and `codegen` also hold every
# `.dart` file under `lib/`, which is checked separately.
_EXPECTED = {
    "run": _DART + _DARTVM,
    "aot_run": _DARTAOTRUNTIME,
    "aot_compile": _DART + _DARTAOTRUNTIME + _DARTDEV + [
        "bin/snapshots/gen_kernel_aot.dart.snapshot",
        "bin/utils/gen_snapshot",
    ],
    "kernel": _DARTAOTRUNTIME + [
        "bin/snapshots/frontend_server_aot.dart.snapshot",
        "bin/snapshots/kernel_worker_aot.dart.snapshot",
        "lib/_internal/vm_platform_product.dill",
        "lib/libraries.json",
    ],
    "format": _DART + _DARTDEV,
    "analyze": _DART + _DARTVM + _DARTAOTRUNTIME + _DARTDEV + _ANALYZER_SDK + [
        "bin/snapshots/analysis_server.dart.snapshot",
        "bin/snapshots/analysis_server_aot.dart.snapshot",
        "lib/_internal/fix_data.yaml",
    ],
    "codegen": _ANALYZER_SDK,
    "dart2js": _DART + _DARTDEV + [
        "bin/snapshots/dart2js_aot.dart.snapshot",
        "lib/_internal/dart2js_platform.dill",
        "lib/_internal/dart2js_server_platform.dill",
        "lib/libraries.json",
    ],
    "dart2wasm": _DART + _DARTAOTRUNTIME + _DARTDEV + [
        "bin/snapshots/dart2wasm_product.snapshot",
        "bin/utils/wasm-opt",
        "lib/_internal/dart2wasm_js_compatibility_platform.dill",
        "lib/_internal/dart2wasm_platform.dill",
        "lib/_internal/dart2wasm_standalone_platform.dill",
    ],
}

_WITH_LIBRARY_SOURCES = ["analyze", "codegen"]

def _sdk_root(sdk):
    return sdk.dart.dirname.rpartition("/")[0]

def _relative(files, root):
    paths = []
    for f in files.to_list():
        if not f.path.startswith(root + "/"):
            fail("%s is not under the SDK root %s" % (f.path, root))
        path = f.path[len(root) + 1:]
        paths.append(path[:-len(".exe")] if path.endswith(".exe") else path)
    return sorted(paths)

def _is_library_source(path):
    return path.startswith("lib/") and path.endswith(".dart")

def _sdk_file_sets_test_impl(ctx):
    env = unittest.begin(ctx)
    sdk = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    root = _sdk_root(sdk)
    asserts.equals(env, sorted(SDK_FILE_SETS.keys()), sorted(_EXPECTED.keys()), "the sets pinned here")
    library_sources = [p for p in _relative(sdk.files.all, root) if _is_library_source(p)]
    asserts.true(env, len(library_sources) > 100, "the SDK has its `dart:` sources under lib/")
    for role, expected in _EXPECTED.items():
        paths = _relative(getattr(sdk.files, role), root)
        if role in _WITH_LIBRARY_SOURCES:
            asserts.equals(env, library_sources, [p for p in paths if _is_library_source(p)], "the `%s` set's lib/ sources" % role)
            paths = [p for p in paths if not _is_library_source(p)]
        asserts.equals(env, sorted(expected), paths, "the `%s` set" % role)
    return unittest.end(env)

sdk_file_sets_test = unittest.make(
    _sdk_file_sets_test_impl,
    toolchains = [_TOOLCHAIN],
)

def _sdk_file_set_copy_impl(ctx):
    sdk = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    root = _sdk_root(sdk)
    out = ctx.actions.declare_directory(ctx.label.name)
    files = getattr(sdk.files, ctx.attr.set).to_list()
    args = ctx.actions.args()
    args.add(out.path)
    for f in files:
        args.add(f.path[len(root) + 1:])
        args.add(f)

    # The analyze set is hundreds of files, past Windows' command-line limit.
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")

    # A copy, not a link: the `dart` launcher finds the VM and its snapshots
    # beside its own resolved path, which for a link is the whole SDK.
    ctx.actions.run(
        executable = ctx.executable._copier,
        arguments = [args],
        inputs = files,
        outputs = [out],
        mnemonic = "SdkFileSetCopy",
        progress_message = "Copying the SDK's %s set" % ctx.attr.set,
    )
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles([out]))]

sdk_file_set_copy = rule(
    implementation = _sdk_file_set_copy_impl,
    attrs = {
        "set": attr.string(mandatory = True, values = SDK_FILE_SETS.keys()),
        "_copier": attr.label(
            default = ":copy_files",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN],
    doc = "A directory holding copies of one SDK file set, laid out as in the SDK.",
)
