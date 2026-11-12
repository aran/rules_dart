"""A platform other than rules_dart's VM, and a program rule compiling for it.

`alt_vm` is what a user with a Dart SDK of their own, or a rule set with its
own platform, supplies: a `DartKernelSdkInfo` naming its compiler, its runtime
kinds and their platform dills. Here they are the pinned SDK's files, linked to
other paths under other names, so a compile that still reached for the
toolchain's files, or for a fixed name, would show it. `alt_program` compiles
a whole program for it, as a rule set outside rules_dart would, on `utils.bzl`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartInfo", "DartKernelSdkInfo")
load(
    "//dart:utils.bzl",
    "KERNEL_TOOL_ATTR",
    "PORTABLE",
    "PORTABLE_EXEC_GROUPS",
    "collect_packages",
    "collect_transitive_srcs",
    "dart_kernel_runtime",
    "dart_whole_program_kernel_action",
)

_SDK_FILES = {
    "runtime": "bin/dartaotruntime",
    "frontend_server": "bin/snapshots/frontend_server_aot.dart.snapshot",
    "product": "lib/_internal/vm_platform_product.dill",
}

# Where each lands in the alternative SDK.
_ALT_PATHS = {
    "runtime": "alt_sdk/bin/alt_runtime",
    "frontend_server": "alt_sdk/bin/alt_frontend.snapshot",
    "other": "alt_sdk/platforms/alt_other_platform.dill",
    "product": "alt_sdk/platforms/alt_product_platform.dill",
}

_SANITIZERS = ["dart.vm.asan=false", "dart.vm.msan=false", "dart.vm.tsan=false"]

def _alt_vm_impl(ctx):
    sdk = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info
    root = sdk.dart.dirname.rsplit("/", 1)[0] + "/"
    found = {}
    for f in sdk.files.kernel.to_list():
        for key, rel in _SDK_FILES.items():
            if f.path in [root + rel, root + rel + ".exe"]:
                found[key] = f
    alt = {}
    for key, rel in _ALT_PATHS.items():
        # `other` is a second platform of the SDK, the product one again
        # under another name: a compile for `alt_product` must not read it.
        source = found["product" if key == "other" else key]

        # Windows starts a program only from a name ending `.exe`.
        if source.extension == "exe":
            rel += ".exe"
        alt[key] = ctx.actions.declare_file(ctx.label.name + "/" + rel)
        ctx.actions.symlink(output = alt[key], target_file = source, is_executable = key == "runtime")
    return [DartKernelSdkInfo(
        target = "vm",
        aot_runtime = alt["runtime"],
        kernel_worker = None,
        frontend_server = alt["frontend_server"],
        runtimes = {
            "alt_other": dart_kernel_runtime(alt["other"], defines = ["dart.vm.product=false"] + _SANITIZERS),
            "alt_product": dart_kernel_runtime(alt["product"], defines = ["dart.vm.product=true"] + _SANITIZERS),
            # A runtime with front-end flags of its own: what it compiles is
            # the product runtime's, with `toString` dropped from the
            # entrypoint's package.
            "alt_stripped": dart_kernel_runtime(
                alt["product"],
                defines = ["dart.vm.product=true"] + _SANITIZERS,
                flags = ["--delete-tostring-package-uri=package:kernel_platform_fixture"],
            ),
        },
        module_runtime = "alt_product",
        libraries_spec = None,
        libraries_target = "vm",
        tool_files = depset(),
        outline_tool = None,
    )]

alt_vm = rule(
    implementation = _alt_vm_impl,
    toolchains = ["//dart:toolchain_type"],
    doc = "A `DartKernelSdkInfo` over the pinned SDK's files under other paths and names.",
)

def _alt_program_impl(ctx):
    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    outputs = {}
    if ctx.attr.record_uses:
        outputs["--recorded-uses"] = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json")
    dart_whole_program_kernel_action(
        ctx,
        kernel_sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo],
        runtime = ctx.attr.runtime,
        main = ctx.file.main,
        srcs = depset(ctx.files.srcs, transitive = [collect_transitive_srcs(ctx.attr.deps)]),
        packages = collect_packages(ctx.attr.deps),
        output_dill = dill,
        entrypoint_uri = ctx.attr.entrypoint_uri or None,
        sources = ctx.attr.sources,
        filesystem_scheme = ctx.attr.filesystem_scheme,
        flags = ctx.attr.flags,
        outputs = outputs,
    )
    return [DefaultInfo(files = depset([dill] + outputs.values()))]

alt_program = rule(
    implementation = _alt_program_impl,
    attrs = KERNEL_TOOL_ATTR | {
        "main": attr.label(allow_single_file = [".dart"], mandatory = True),
        "srcs": attr.label_list(allow_files = [".dart"]),
        "deps": attr.label_list(providers = [DartInfo]),
        "runtime": attr.string(mandatory = True),
        "entrypoint_uri": attr.string(),
        "sources": attr.string_list(),
        "filesystem_scheme": attr.string(default = "org-dartlang-root"),
        "flags": attr.string_list(),
        "record_uses": attr.bool(),
        "_kernel_sdk": attr.label(
            default = ":alt_vm",
            providers = [DartKernelSdkInfo],
            cfg = config.exec(PORTABLE),
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
)

def _kernel_action(env):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(actions), "one DartKernel action")
    return actions[0]

def _flag_value(argv, flag):
    for i, a in enumerate(argv):
        if a == flag:
            return argv[i + 1]
    return None

def _compiles_with_the_platform_given_impl(ctx):
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = action.argv
    inputs = [f.path for f in action.inputs.to_list()]

    # The compiler, its runtime and the platform of the runtime asked for come
    # from the platform given, and nothing of the toolchain's SDK is read.
    for key in ["runtime", "frontend_server", "product"]:
        asserts.true(env, [p for p in inputs if p.removesuffix(".exe").endswith(_ALT_PATHS[key])], "reads the alternative " + key)
    asserts.false(env, [p for p in inputs if p.endswith(_ALT_PATHS["other"])], "reads no other runtime's platform")
    asserts.false(env, [p for p in inputs if "/lib/_internal/" in p or "/bin/snapshots/" in p], "reads nothing of the toolchain's SDK: %s" % inputs)
    asserts.equals(env, "alt_product_platform.dill", _flag_value(argv, "--platform"))
    asserts.true(env, "-Ddart.vm.product=true" in argv, "the runtime's declarations")
    asserts.true(env, _flag_value(argv, "--sdk-root").endswith("alt_sdk/platforms/"), "the platform's directory is the SDK root")
    asserts.equals(env, "vm", _flag_value(argv, "--target"))
    asserts.true(env, "-Ddart.vm.product=false" not in argv, "no other runtime's declarations")

    # The caller's scheme, entrypoint, further libraries and outputs.
    asserts.equals(env, "org-dartlang-app", _flag_value(argv, "--filesystem-scheme"))
    asserts.true(env, _flag_value(argv, "--packages").startswith("org-dartlang-app:///"), "the package config is read through the scheme")
    asserts.equals(env, "org-dartlang-app:///dart/tests/kernel_platform_fixture/bin/extra.dart", _flag_value(argv, "--source"))
    asserts.true(env, _flag_value(argv, "--recorded-uses").endswith("custom_program.recorded_uses.json"), "the further output is named")
    asserts.true(env, [o for o in action.outputs.to_list() if o.basename == "custom_program.recorded_uses.json"], "and declared")
    asserts.equals(env, "package:kernel_platform_fixture/app.dart", argv[-1])

    # The runtime's own flags, before the caller's.
    flag = "--delete-tostring-package-uri=package:kernel_platform_fixture"
    asserts.true(env, flag in argv, "the runtime's flags")
    asserts.true(env, argv.index(flag) < argv.index("--aot"), "before the caller's")
    return analysistest.end(env)

compiles_with_the_platform_given_test = analysistest.make(_compiles_with_the_platform_given_impl)

def _names_no_runtime_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "the `vm` platform has no runtime \"product\"; it has alt_other, alt_product, alt_stripped")
    return analysistest.end(env)

names_no_runtime_test = analysistest.make(_names_no_runtime_impl, expect_failure = True)

def _refuses_resolve_dwarf_paths_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "`--resolve-dwarf-paths` cannot be used")
    return analysistest.end(env)

refuses_resolve_dwarf_paths_test = analysistest.make(_refuses_resolve_dwarf_paths_impl, expect_failure = True)

def _tool_ignores_the_build_impl(ctx):
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    asserts.true(env, "--track-creation-locations" not in action.argv, "the tool does not track creation locations")
    asserts.false(env, [a for a in action.argv if a.startswith("-DA=")], "the tool takes no command-line declaration")
    return analysistest.end(env)

# A tool reached from a build that tracks creation locations and declares a
# value `gen_kernel` would split, as a Flutter test's runner reaches the
# launcher: the tool is compiled as in any other build.
tool_ignores_the_build_test = analysistest.make(
    _tool_ignores_the_build_impl,
    config_settings = {
        str(Label("//dart:track_creation_locations")): True,
        str(Label("//dart:extra_dart_defines")): ["A=x,y"],
    },
)
