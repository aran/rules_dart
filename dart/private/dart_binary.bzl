"""Implementation of the dart_binary rule."""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartCompileInfo", "DartInfo")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_packages",
    "collect_transitive_code_assets",
    "collect_transitive_srcs",
    "gen_kernel_native_assets_action",
    "generate_native_assets_yaml",
    "generate_package_config",
    "resolve_code_assets",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "dart_compile_action")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "colocate_entrypoint", "colocate_packages")

def binary_output_basename(name, compile_mode, is_windows):
    """Returns a `dart_binary`'s output filename with the platform exe extension.

    Includes the platform-appropriate executable extension.

    A native `exe` gets a `.exe` suffix on Windows so it is launchable and
    discoverable by the conventional name (e.g. via runfiles
    `rlocation("…/app.exe")`). Without it the output is a bare `app`, and a
    consumer looking up `app.exe` misses — falling through to a non-existent
    path. The snapshot modes use fixed extensions on every platform.

    Args:
      name: The target name (`ctx.label.name`).
      compile_mode: One of `exe`, `aot-snapshot`, `kernel`, `jit-snapshot`.
      is_windows: Whether the target platform is Windows.

    Returns:
      The output filename string.
    """
    if compile_mode == "exe":
        return name + (".exe" if is_windows else "")
    elif compile_mode == "aot-snapshot":
        return name + ".aot"
    elif compile_mode == "kernel":
        return name + ".dill"
    elif compile_mode == "jit-snapshot":
        return name + ".jit"
    fail("Unknown compile_mode: %s" % compile_mode)

def _dart_binary_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # Co-locate each dep package's source+generated (and split-across-targets)
    # files into one real directory, and the binary's own `main` with any
    # generated sibling sources, so the compile resolves everything.
    packages = collect_packages(ctx.attr.deps)

    if ctx.attr.code_assets_from_deps:
        hook_err = check_unreplaced_hooks(ctx.label, packages)
        if hook_err != None:
            fail(hook_err)

    # The one flatten per rule: colocation inspects per-file paths.
    packages, dep_srcs = colocate_packages(ctx, packages, collect_transitive_srcs(ctx.attr.deps).to_list())
    main_input, main_arg, own_inputs = colocate_entrypoint(ctx, ctx.file.main, ctx.files.srcs)
    all_srcs = dep_srcs + own_inputs

    # Root resolution must see the rule's own inputs too: a package whose
    # metadata comes from a srcs-less façade library resolves only via the
    # files this rule supplies itself.
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = generate_package_config(packages, all_srcs, package_config),
    )

    # Determine output filename (Windows gets the `.exe` extension — see
    # `binary_output_basename`).
    compile_mode = ctx.attr.compile_mode
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._os_windows[platform_common.ConstraintValueInfo],
    )
    output = ctx.actions.declare_file(
        binary_output_basename(ctx.label.name, compile_mode, is_windows),
    )

    # By default compile the source main directly. With native code assets,
    # first run gen_kernel with the asset mapping embedded (its `relative`
    # paths resolve against the final executable at runtime), then compile the
    # resulting kernel — `dart compile` accepts a `.dill` input and the
    # metadata flows through into the snapshot.
    compile_main = main_input
    compile_main_arg = main_arg
    compile_srcs = all_srcs
    compile_package_config = package_config
    code_asset_libs = []

    # Assets reach a binary two ways: propagated from any package in `deps`
    # that owns one (the upstream semantics — depending on a package gets you
    # its assets), or named outright. The explicit attr stays valid for
    # hand-written cases; it is simply no longer the only mechanism.
    resolved_assets = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(ctx.attr.deps) if ctx.attr.code_assets_from_deps else [],
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )

    if resolved_assets:
        abi = target_dart_abi(ctx)
        entries, code_asset_libs = code_asset_entries(
            ctx.label,
            resolved_assets,
            output.dirname,
        )
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(abi, entries),
        )
        dill = ctx.actions.declare_file(ctx.label.name + ".na.dill")
        gen_kernel_native_assets_action(
            ctx = ctx,
            dart_sdk_info = dart_sdk_info,
            main = main_input,
            transitive_srcs = depset(all_srcs),
            package_config = package_config,
            native_assets_yaml = native_assets_yaml,
            output_dill = dill,
            main_path = main_arg,
        )
        compile_main = dill
        compile_main_arg = None
        compile_srcs = []
        compile_package_config = None

    # Run dart compile
    dart_compile_action(
        ctx = ctx,
        dart_bin = dart_sdk_info.dart,
        sdk_files = dart_sdk_info.tool_files,
        main = compile_main,
        main_path = compile_main_arg,
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
        "code_assets_from_deps": attr.bool(
            default = True,
            doc = """Whether to pick up native code assets propagated through `deps`.

Leave this on for a program that runs the packages it depends on. Turn it off for a `dart_binary` \
used purely as a *build tool* — a code generator, a linter — which imports pub packages for their \
Dart API but never loads their native libraries. Without the opt-out such a tool would build (and \
in an exec configuration, cross-build) every native library anywhere in its dependency closure. \
rules_dart's own `dart/ext` builder shims set this to `False`: `drift_dev` depends on \
`package:sqlite3`, but generating code never calls into libsqlite3.

Also suppresses the unreplaced-`hook/build.dart` diagnostic, on the same grounds — a tool that \
never loads native code is unaffected by a package whose native code was not built.""",
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
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles a Dart application using `dart compile`.",
)
