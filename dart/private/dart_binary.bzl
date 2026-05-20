"""Implementation of the dart_binary rule."""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartCompileInfo", "DartInfo")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "collect_packages",
    "collect_transitive_srcs",
    "gen_kernel_native_assets_action",
    "generate_native_assets_yaml",
    "generate_package_config",
    "relative_path",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "dart_compile_action")

def _generate_package_config(ctx, deps, all_srcs):
    """Generate a package_config.json from the transitive DartInfo deps."""
    packages = collect_packages(deps)
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")

    content = generate_package_config(packages, all_srcs, package_config)
    ctx.actions.write(output = package_config, content = content)
    return package_config

def _dart_binary_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # Collect all transitive sources from deps
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps)

    # Generate package_config.json
    package_config = _generate_package_config(ctx, ctx.attr.deps, all_srcs)

    # Determine output filename
    compile_mode = ctx.attr.compile_mode
    if compile_mode == "exe":
        output = ctx.actions.declare_file(ctx.label.name)
    elif compile_mode == "aot-snapshot":
        output = ctx.actions.declare_file(ctx.label.name + ".aot")
    elif compile_mode == "kernel":
        output = ctx.actions.declare_file(ctx.label.name + ".dill")
    elif compile_mode == "jit-snapshot":
        output = ctx.actions.declare_file(ctx.label.name + ".jit")
    else:
        fail("Unknown compile_mode: %s" % compile_mode)

    # By default compile the source main directly. With native code assets,
    # first run gen_kernel with the asset mapping embedded (its `relative`
    # paths resolve against the final executable at runtime), then compile the
    # resulting kernel — `dart compile` accepts a `.dill` input and the
    # metadata flows through into the snapshot.
    compile_main = ctx.file.main
    compile_srcs = all_srcs
    compile_package_config = package_config
    code_asset_libs = []

    if ctx.attr.code_assets:
        abi = target_dart_abi(ctx)
        entries = []
        for dep in ctx.attr.code_assets:
            info = dep[DartCodeAssetInfo]
            entries.append((info.asset_id, relative_path(output.dirname, info.dynamic_library.path)))
            code_asset_libs.append(info.dynamic_library)
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(abi, entries),
        )
        dill = ctx.actions.declare_file(ctx.label.name + ".na.dill")
        gen_kernel_native_assets_action(
            ctx = ctx,
            dart_sdk_info = dart_sdk_info,
            main = ctx.file.main,
            transitive_srcs = depset(all_srcs),
            package_config = package_config,
            native_assets_yaml = native_assets_yaml,
            output_dill = dill,
        )
        compile_main = dill
        compile_srcs = []
        compile_package_config = None

    # Run dart compile
    dart_compile_action(
        ctx = ctx,
        dart_bin = dart_sdk_info.dart,
        sdk_files = dart_sdk_info.tool_files,
        main = compile_main,
        srcs = compile_srcs,
        package_config = compile_package_config,
        output = output,
        compile_mode = compile_mode,
        target_os = dart_sdk_info.target_os,
        target_arch = dart_sdk_info.target_arch,
        extra_flags = ctx.attr.dart_compile_flags,
        defines = ctx.attr.defines,
    )

    runfiles = ctx.runfiles(files = ctx.files.data + code_asset_libs).merge_all(
        [dep[DefaultInfo].default_runfiles for dep in ctx.attr.data],
    )

    return [
        DefaultInfo(
            files = depset([output]),
            executable = output,
            runfiles = runfiles,
        ),
        DartCompileInfo(
            executable = output,
            compile_mode = compile_mode,
        ),
    ]

dart_binary = rule(
    implementation = _dart_binary_impl,
    attrs = dict({
        "main": attr.label(
            doc = "The Dart entrypoint file containing a top-level `main()` function.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart source files that are part of this binary's package but not reachable via `deps`.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "`dart_library` targets this binary depends on.",
            providers = [DartInfo],
        ),
        "data": attr.label_list(
            doc = "Additional files needed at runtime. These are added to runfiles so they can be found via the runfiles tree when using `bazel run`.",
            allow_files = True,
        ),
        "code_assets": attr.label_list(
            doc = """Native code assets (e.g. `//dart/ext/sqlite3:code_asset`) the binary's \
`@Native` FFI bindings resolve against. When set, the main is compiled to a kernel with the \
code-asset mapping embedded (`gen_kernel --native-assets`) before the snapshot/exe is produced, \
and the libraries are staged in runfiles so the Dart VM resolves them relative to the executable \
at runtime. Each entry must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule).""",
            providers = [DartCodeAssetInfo],
        ),
        "compile_mode": attr.string(
            doc = """\
The `dart compile` mode. Determines the output format:

- `exe` (default): Self-contained native machine code. No Dart SDK needed at runtime. Best for deployment.
- `aot-snapshot`: AOT-compiled snapshot. Requires `dartaotruntime` to execute. Smaller than `exe`.
- `kernel`: Dart kernel binary (`.dill`). Requires `dart` to execute. Fastest compilation, useful for development.
- `jit-snapshot`: JIT snapshot with trained profile data. Requires `dart` to execute. Fastest startup after warmup.
""",
            default = "exe",
            values = ["exe", "aot-snapshot", "kernel", "jit-snapshot"],
        ),
        "dart_compile_flags": attr.string_list(
            doc = "Extra flags passed to `dart compile` after compilation-mode defaults. Flags appear last so they can override defaults (e.g., `--extra-gen-snapshot-options=--optimization_level=3`).",
        ),
        "defines": attr.string_list(
            doc = "Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` flag.",
        ),
    }, **DART_ABI_CONSTRAINT_ATTRS),
    executable = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Compiles a Dart application using `dart compile`.",
)
