"""Implementation of the dart_binary rule."""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartCompileInfo", "DartInfo", "DartRecordedUsesInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_vm_dart_defines")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_transitive_code_assets",
    "collect_transitive_resources",
    "generate_native_assets_yaml",
    "resolve_code_assets",
    "stage_code_assets",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "dart_compile_action", "front_end_flags", "recorded_uses_kind")
load("//dart/private:dart_import_check.bzl", "dart_import_check_aspect", "import_check_validation")
load("//dart/private:dart_module.bzl", "KERNEL_TOOL_ATTR", "whole_program_kernel")
load("//dart/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//dart/private:executable_package.bzl", "EXECUTABLE_PACKAGE_ATTRS", "executable_package")

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

    own = executable_package(ctx, [ctx.file.main] + ctx.files.srcs)
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

    # Two steps for every mode: the front end produces a kernel, read through a
    # filesystem rooted at the exec root so the output does not depend on where
    # the action ran (see `dart_kernel_action`), and `dart compile` turns it
    # into the requested output. A `kernel` is the first step's output itself.
    defines = merge_vm_dart_defines(ctx)
    fe_flags, compile_flags = front_end_flags(ctx.attr.dart_compile_flags)
    code_asset_libs = []

    # Assets reach a binary two ways: propagated from any package in `deps`
    # that owns one (the upstream semantics — depending on a package gets you
    # its assets), or named outright. The explicit attr stays valid for
    # hand-written cases; it is simply no longer the only mechanism. The
    # mapping is embedded in the kernel, its `relative` paths resolved against
    # the final executable at run time: each library is linked into
    # `<name>.native/` beside it, so the path holds wherever the executable and
    # that directory go together.
    resolved_assets = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(ctx.attr.deps) if ctx.attr.code_assets_from_deps else [],
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )
    native_assets_yaml = None
    if resolved_assets:
        abi = target_dart_abi(ctx)
        entries, code_asset_libs = code_asset_entries(
            ctx.label,
            _stage_libraries(ctx, resolved_assets),
            output.dirname,
        )
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(abi, entries),
        )

    kernel = output if compile_mode == "kernel" else ctx.actions.declare_file(ctx.label.name + ".app.dill")
    whole_program_kernel(
        ctx,
        main = ctx.file.main,
        packages = packages,
        output_dill = kernel,
        product = compile_mode != "jit-snapshot",
        defines = defines,
        # A `kernel` has no second step, so every flag belongs to the first.
        flags = ctx.attr.dart_compile_flags if compile_mode == "kernel" else fe_flags,
        native_assets_yaml = native_assets_yaml,
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

    if compile_mode != "kernel":
        dart_compile_action(
            ctx = ctx,
            sdk = dart_sdk_info,
            kernel = kernel,
            output = output,
            compile_mode = compile_mode,
            extra_flags = compile_flags,
            recorded_uses = compile_recorded_uses,
            runner = _compile_runner(ctx, compile_mode),
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
            files = depset([output] + code_asset_libs),
            executable = output,
            runfiles = runfiles,
        ),
        DartCompileInfo(
            executable = output,
            compile_mode = compile_mode,
        ),
        # What makes the `dart_analyze` aspect and `dart_fix` reach this entrypoint
        # without making this target a legal `deps` entry.
        own.analyzable,
    ] + recorded_uses_info + _import_checks(ctx, own)

def _stage_libraries(ctx, assets):
    directory = ctx.label.name + ".native"
    owners = {}
    for asset in assets:
        library = asset.dynamic_library
        if library == None:
            continue
        previous = owners.get(library.basename)
        if previous and previous[0] != library:
            fail("%s: code assets %s and %s both have a library named %s, and a binary's libraries share one directory" % (
                ctx.label,
                previous[1],
                asset.asset_id,
                library.basename,
            ))
        owners[library.basename] = (library, asset.asset_id)
    return stage_code_assets(ctx, assets, lambda _index: directory)

def _compile_runner(ctx, compile_mode):
    # Only gen_snapshot's Mach-O output names where it was written.
    if not hasattr(ctx.attr, "_compile_runner") or compile_mode not in ("exe", "aot-snapshot"):
        return None
    if not ctx.target_platform_has_constraint(ctx.attr._os_macos[platform_common.ConstraintValueInfo]):
        return None
    return ctx.file._compile_runner

def _import_checks(ctx, own):
    # `dart_tool_binary` has no `kernel_tool` to check with: it builds it.
    if not hasattr(ctx.attr, "_kernel_tool"):
        return []
    return [OutputGroupInfo(_validation = import_check_validation(
        ctx,
        ctx.executable._kernel_tool,
        [ctx.file.main] + ctx.files.srcs,
        own.record,
        ctx.attr.deps,
    ))]

_COMPILE_RUNNER_ATTR = {
    "_compile_runner": attr.label(
        default = "//dart/private/tools:compile_runner",
        allow_single_file = True,
        cfg = "exec",
    ),
}

def _dart_binary_rule(check_imports, compile_runner = True):
    return rule(
        implementation = _dart_binary_impl,
        attrs = dict(
            KERNEL_TOOL_ATTR if check_imports else {},
            **dict(_COMPILE_RUNNER_ATTR if compile_runner else {}, **dict({
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
                    aspects = [dart_import_check_aspect] if check_imports else [],
                ),
                "data": attr.label_list(
                    doc = "Additional files needed at runtime. These are added to runfiles so they can be found via the runfiles tree when using `bazel run`.",
                    allow_files = True,
                ),
                "code_assets": attr.label_list(
                    doc = """Native code assets (e.g. `//dart/ext/sqlite3:code_asset`) the binary's \
    `@Native` FFI bindings resolve against. When set, the main is compiled to a kernel with the \
    code-asset mapping embedded (`gen_kernel --native-assets`) before the snapshot/exe is produced, \
    and the libraries are linked into `<name>.native/` beside the executable, where the Dart VM \
    finds them at runtime: to install the binary, copy the executable and that directory together, following links (`cp -RL`), because the files there are symlinks into the output tree. Each entry must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule). An entry replaces the asset with the same id that `deps` supply, so a binary can load a differently built library under that id.""",
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
                    doc = "Extra flags passed to `dart compile` after compilation-mode defaults. Flags appear last so they can override defaults (e.g., `--extra-gen-snapshot-options=--optimization_level=3`). Front-end flags (`--enable-experiment`, `-D`/`--define`) go to the front-end step that precedes `dart compile`, and `--verbosity` to both; in the `kernel` mode, which is that step alone, every flag does, and only those the front end (`gen_kernel`) accepts work.",
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
            }, **dict(DART_ABI_CONSTRAINT_ATTRS, **dict(EXTRA_DART_DEFINES_ATTR, **EXECUTABLE_PACKAGE_ATTRS))))
        ),
        executable = True,
        # The default group compiles machine code for the target, so its SDK
        # matches the target; the kernel before it is `portable`.
        toolchains = ["//dart:toolchain_type"],
        exec_groups = PORTABLE_EXEC_GROUPS,
        doc = "Compiles a Dart application using `dart compile`.",
    )

dart_binary = _dart_binary_rule(check_imports = True)

# `kernel_tool` itself, which checks everyone else's imports: built without the
# check, which would depend on it. Only for rules_dart's own tools.
dart_tool_binary = _dart_binary_rule(check_imports = False)

# `compile_runner`, which every macOS `exe` and `aot-snapshot` compiles
# through: a `kernel`, which does not, built by a rule that does not depend on
# it. Goes when `compile_runner` does (see its header).
dart_bootstrap_binary = _dart_binary_rule(check_imports = False, compile_runner = False)
