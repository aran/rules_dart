"""Implementation of the dart_test rule.

Unified with `dart_binary`: the test's `main` is compiled to a self-contained
a `.dill` **at build time**, so package resolution and `part`/`import`
co-location happen in the execroot — exactly where `dart_binary` already proves
they work — and the test launcher merely runs the dill. No sources, no
`package_config`, and no co-location are needed at runtime, so manifest-mode
runfiles (Windows) are a non-issue.
"""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_dart_defines")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "WINDOWS_CONSTRAINT_ATTR",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_packages",
    "collect_transitive_code_assets",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "create_test_executable",
    "dart_cfe_action",
    "generate_native_assets_yaml",
    "generate_package_config",
    "resolve_code_assets",
    "runfiles_path",
    "target_dart_abi",
)
load("//dart/private:dart_info.bzl", "dart_analyzable_info")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "colocate_entrypoint", "colocate_packages")

def _dart_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    workspace_name = ctx.workspace_name

    # Co-locate each dep package's source+generated (and split-across-targets)
    # files into one real directory, and the test's own `main` with any generated
    # sibling sources (e.g. a `.mocks.dart`), so the build-time compile resolves
    # everything.
    packages = collect_packages(ctx.attr.deps)

    hook_err = check_unreplaced_hooks(ctx.label, packages)
    if hook_err != None:
        fail(hook_err)

    # The one flatten per rule: colocation inspects per-file paths.
    packages, dep_srcs = colocate_packages(ctx, packages, collect_transitive_srcs(ctx.attr.deps).to_list())
    main_input, main_arg, own_inputs = colocate_entrypoint(ctx, ctx.file.main, ctx.files.srcs)
    compile_srcs = dep_srcs + own_inputs

    # Root resolution must see the rule's own inputs too: a package whose
    # metadata comes from a srcs-less façade library resolves only via the
    # files this rule supplies itself.
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = generate_package_config(packages, compile_srcs, package_config),
    )

    dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    defines = merge_dart_defines(ctx)
    runtime_libs = []

    # Transitively propagated assets plus any named outright — see the same
    # comment in `dart_binary`.
    resolved_assets = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(ctx.attr.deps),
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )

    native_assets_yaml = None
    if resolved_assets:
        # Embed the code-asset mapping in the `.dill` (`gen_kernel --native-assets`),
        # with `relative` paths resolved against the dill at runtime — the same
        # build-time path `dart_binary` uses. The `.so` libraries ship in runfiles.
        abi = target_dart_abi(ctx)
        entries, runtime_libs = code_asset_entries(
            ctx.label,
            resolved_assets,
            dill.dirname,
        )
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(abi, entries),
        )

    dart_cfe_action(
        ctx = ctx,
        dart_sdk_info = dart_sdk_info,
        main = main_input,
        transitive_srcs = depset(compile_srcs),
        package_config = package_config,
        output_dill = dill,
        main_path = main_arg,
        defines = defines,
        native_assets_yaml = native_assets_yaml,
    )

    # Thin launcher: run the self-contained dill with asserts enabled. The dill
    # carries all sources/imports, so runfiles need only the VM and (for code
    # assets) the `.so` libraries.
    executable, env_info, tool_runfiles = create_test_executable(
        ctx,
        ctx.attr._tool,
        env = {
            "RULES_DART_DART": runfiles_path(dart_sdk_info.dart, workspace_name),
            "RULES_DART_DILL": runfiles_path(dill, workspace_name),
        },
    )

    # A dep's `lib/**` non-Dart files are part of the package at run time under
    # pub, and the dill carries only compiled code — so they come in here, the
    # same way `dart_binary` stages them, and are reached with `rlocation`.
    runfiles = ctx.runfiles(
        files = [dill] + runtime_libs + ctx.files.data,
        transitive_files = depset(
            transitive = [
                dart_sdk_info.tool_files,
                collect_transitive_resources(ctx.attr.deps),
            ],
        ),
    )
    runfiles = runfiles.merge(tool_runfiles)
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        env_info,
        # See `dart_binary`: analyzable and fixable without becoming a valid
        # `deps` entry. `ctx.file.main` is the pre-colocation file, because the
        # analyze/fix rules stage by `short_path`.
        dart_analyzable_info(
            deps = ctx.attr.deps,
            srcs = [ctx.file.main] + ctx.files.srcs,
        ),
    ]

dart_test = rule(
    implementation = _dart_test_impl,
    attrs = dict({
        "main": attr.label(
            doc = "The Dart test file to run. Must contain a top-level `main()` function.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart source files that are part of this test's package but not reachable via `deps`.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "`dart_library` targets this test depends on.",
            providers = [DartInfo],
        ),
        "data": attr.label_list(
            doc = "Additional files needed at runtime. These are added to runfiles so they can be resolved via `Runfiles.rlocation()`.",
            allow_files = True,
        ),
        "defines": attr.string_list(
            doc = """Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` \
flag on the build-time compile, so `String.fromEnvironment` resolves to it. Set these here rather \
than at run time: the test's `main` is compiled to a `.dill` during the build, and environment \
declarations are resolved by the CFE at that point — the VM cannot supply them later.""",
        ),
        "code_assets": attr.label_list(
            doc = """Native code assets (e.g. `//dart/ext/sqlite3:code_asset`) the test's \
`@Native` FFI bindings resolve against. When set, the test's `main` is compiled to a `.dill` \
with the code-asset mapping embedded (`gen_kernel --native-assets`), and the libraries ship in \
runfiles so the Dart VM resolves them — no `dart:ffi` ceremony in the test source. Each entry \
must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule).""",
            providers = [DartCodeAssetInfo],
        ),
        "_tool": attr.label(
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = "exec",
        ),
    }, **dict(WINDOWS_CONSTRAINT_ATTR, **dict(DART_ABI_CONSTRAINT_ATTRS, **EXTRA_DART_DEFINES_ATTR))),
    test = True,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles a Dart test to a `.dill` at build time and runs it with asserts enabled.",
)
