"""Implementation of the dart_binary rule."""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartCompileInfo", "DartInfo", "DartRecordedUsesInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_dart_defines")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_transitive_code_assets",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "generate_native_assets_yaml",
    "generate_stable_package_config",
    "resolve_code_assets",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "dart_compile_action", "recorded_uses_kind")
load(
    "//dart/private:dart_kernel.bzl",
    "BINARY_MODULAR_KERNEL_ATTRS",
    "DartKernelInfo",
    "MODULAR_KERNEL_TOOLCHAINS",
    "dart_kernel_module_aspect",
    "entry_sources",
    "modular_executable_kernel",
    "modular_executable_tools",
)
load("//dart/private:dart_test_runner.bzl", "DartTestRunnerMainInfo")
load("//dart/private:executable_package.bzl", "EXECUTABLE_PACKAGE_ATTRS", "executable_package")
load("//dart/private:source_set.bzl", "executable_inputs")

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

    own_files = [ctx.file.main] + ctx.files.srcs
    own = executable_package(ctx, own_files)
    packages = own.packages

    if ctx.attr.code_assets_from_deps:
        hook_err = check_unreplaced_hooks(ctx.label, packages)
        if hook_err != None:
            fail(hook_err)

    # Determine output filename (Windows gets the `.exe` extension — see
    # `binary_output_basename`).
    compile_mode = ctx.attr.compile_mode
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._os_windows[platform_common.ConstraintValueInfo],
    )
    output = ctx.actions.declare_file(
        binary_output_basename(ctx.label.name, compile_mode, is_windows),
    )

    # Assets reach a binary two ways: propagated from any package in `deps`
    # that owns one (the upstream semantics — depending on a package gets you
    # its assets), or named outright. The explicit attr stays valid for
    # hand-written cases; it is simply no longer the only mechanism.
    resolved_assets = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(ctx.attr.deps) if ctx.attr.code_assets_from_deps else [],
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )

    # The compiler records the uses of `@RecordUse` definitions only when it
    # tree-shakes, so the other modes get the file it writes when there is
    # nothing to record: a link hook then runs over no uses, as for a program
    # that uses none.
    compile_recorded_uses = None
    recorded_uses_info = []
    if ctx.attr.record_use:
        recorded_uses = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json")
        kind = recorded_uses_kind(compile_mode)
        if kind == "aot":
            compile_recorded_uses = recorded_uses
        else:
            ctx.actions.write(output = recorded_uses, content = "{}")
        recorded_uses_info = [DartRecordedUsesInfo(file = recorded_uses, kind = kind)]

    code_asset_libs = []
    kernel_tools = modular_executable_tools(
        ctx,
        own_files,
        own.record,
        kernel_mode = (compile_mode == "kernel" and ctx.attr.modular_kernel),
        resolved_assets = resolved_assets,
        own_defines = ctx.attr.defines,
        compile_flags = ctx.attr.dart_compile_flags,
    )
    if kernel_tools != None:
        modular_executable_kernel(
            ctx,
            kernel_tools,
            entry_sources(own_files),
            packages,
            [dep[DartKernelInfo] for dep in ctx.attr.deps],
            output,
        )
    else:
        # Nothing is copied: a package split between the source tree and `bazel-out`
        # compiles in place, through the multi-root file system (`executable_inputs`).
        # The one flatten per rule: the package lookup inspects per-file paths.
        inputs = executable_inputs(
            packages,
            collect_transitive_srcs(ctx.attr.deps).to_list(),
            ctx.file.main,
            ctx.files.srcs,
            own.record,
        )
        packages = inputs.packages
        main_input = inputs.main_input
        main_arg = inputs.main_arg
        all_srcs = inputs.srcs

        # Root resolution must see the rule's own inputs too: a package whose
        # metadata comes from a srcs-less façade library resolves only via the
        # files this rule supplies itself.
        package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
        ctx.actions.write(
            output = package_config,
            content = generate_stable_package_config(packages, all_srcs, inputs.roots),
        )

        native_assets_yaml = None
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

        # Run dart compile
        dart_compile_action(
            ctx = ctx,
            dart_sdk_info = dart_sdk_info,
            main = main_input,
            main_path = main_arg,
            srcs = all_srcs,
            package_config = package_config,
            output = output,
            compile_mode = compile_mode,
            target_os = dart_sdk_info.target_os,
            target_arch = dart_sdk_info.target_arch,
            extra_flags = ctx.attr.dart_compile_flags,
            defines = merge_dart_defines(ctx),
            recorded_uses = compile_recorded_uses,
            jit_tool = ctx.file._jit_tool,
            native_assets_yaml = native_assets_yaml,
            embed_sources = DartTestRunnerMainInfo not in ctx.attr.main,
        )

    # Resources ride the runfiles, not the compile. A dep's `lib/**` non-Dart
    # files are part of the package at run time under pub, and the compiled
    # binary is the one place that cannot recover them: `Isolate.resolvePackageUri`
    # returns null in an AOT binary with no package_config above it, so a
    # package cannot read its own shipped files back out. Staging them here is
    # what makes `rlocation` work for them.
    runfiles = ctx.runfiles(
        files = ctx.files.data + code_asset_libs,
        transitive_files = collect_transitive_resources(ctx.attr.deps),
    ).merge_all(
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
        # What makes the `dart_analyze` aspect and `dart_fix` reach this entrypoint
        # without making this target a legal `deps` entry. Staging goes by
        # `short_path`, which is the source file's own path.
        own.analyzable,
    ] + recorded_uses_info

def _dart_binary_attrs(modular = False):
    return dict({
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
            aspects = [dart_kernel_module_aspect] if modular else [],
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
- `jit-snapshot`: JIT snapshot with trained profile data. Requires `dart` to execute. Fastest startup after warmup. The program is trained once, with no arguments, in a fixed-length scratch directory. The snapshot is reproducible only if that training run is deterministic: a program that reads the clock, random numbers, or files outside the build gives a different snapshot each build. The training runs from a copy of the SDK's `dart` at a fixed path per SDK version, so the snapshot does not depend on where the SDK is installed.
""",
            default = "exe",
            values = ["exe", "aot-snapshot", "kernel", "jit-snapshot"],
        ),
        "dart_compile_flags": attr.string_list(
            doc = """\
Extra compiler flags, appended after the compilation-mode defaults so they can override them (e.g., `--extra-gen-snapshot-options=--optimization_level=3`).

Each flag goes to the stage that consumes it. A source entrypoint is first compiled to a kernel by `gen_kernel`, the Dart front end, and then by `dart compile`. The front end takes these flags, so they go to `gen_kernel`:

- `--enable-experiment=<name>`, or `--enable-experiment <name>`
- `-D<KEY=VALUE>`, `--define=<KEY=VALUE>`, or `-D <KEY=VALUE>`, `--define <KEY=VALUE>`
- `--enable-asserts`

Every other flag goes to `dart compile`. In the `kernel` mode all flags go to `gen_kernel`, which is that mode's compile. For a pre-built kernel, all flags go to `dart compile`. The `jit-snapshot` mode takes no `dart compile` flags, so any other flag there is an error.""",
        ),
        "_jit_tool": attr.label(
            default = "//dart/private/tools:app_jit_snapshot.dart",
            allow_single_file = True,
        ),
        "defines": attr.string_list(
            doc = "Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` flag.",
        ),
        "record_use": attr.bool(
            doc = """Record the uses of `@RecordUse` definitions (`package:meta`) as \
`<name>.recorded_uses.json`, provided as `DartRecordedUsesInfo` for `dart_link_hook`. \
In the `exe` and `aot-snapshot` modes the compiler records them as it tree-shakes. The \
`kernel` and `jit-snapshot` modes do not tree-shake, so nothing is recorded and the file is \
the empty JSON object `{}` (`kind = "empty"`).""",
        ),
    }, **dict(DART_ABI_CONSTRAINT_ATTRS, **dict(EXTRA_DART_DEFINES_ATTR, **dict(EXECUTABLE_PACKAGE_ATTRS, **BINARY_MODULAR_KERNEL_ATTRS))))

_dart_binary = rule(
    implementation = _dart_binary_impl,
    attrs = _dart_binary_attrs(modular = False),
    executable = True,
    toolchains = ["//dart:toolchain_type"] + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Dart application using `dart compile`.",
)

_dart_binary_modular = rule(
    implementation = _dart_binary_impl,
    attrs = _dart_binary_attrs(modular = True),
    executable = True,
    toolchains = ["//dart:toolchain_type"] + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Dart application using `dart compile`.",
)

def dart_binary(compile_mode = "exe", modular_kernel = True, **kwargs):
    """Compiles a Dart application using `dart compile`."""
    rule_fn = (
        _dart_binary_modular
        if (compile_mode == "kernel" and modular_kernel)
        else _dart_binary
    )
    rule_fn(
        compile_mode = compile_mode,
        modular_kernel = modular_kernel,
        **kwargs
    )

