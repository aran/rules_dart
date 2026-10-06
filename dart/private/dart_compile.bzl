"""Shared compilation action helpers for Dart."""

load("//dart/private:common.bzl", "writable_home_env")

# The `dart compile` modes that tree-shake, and so can record the uses of
# `@RecordUse` definitions: what survives tree-shaking is the set of uses.
RECORDING_COMPILE_MODES = ("exe", "aot-snapshot")

def recorded_uses_kind(compile_mode):
    """The `DartRecordedUsesInfo.kind` a `dart_binary` in `compile_mode` provides.

    Args:
        compile_mode: The `dart compile` mode.

    Returns:
        `aot` when the compiler records the uses, `empty` when it cannot.
    """
    return "aot" if compile_mode in RECORDING_COMPILE_MODES else "empty"

def defines_stage_error(defines, package_config):
    """Returns an error string if `defines` would reach the compiler too late.

    `-D` values are consumed by the front end during constant evaluation —
    `String.fromEnvironment` and friends resolve there, not at run time. When
    `main` is a pre-built kernel (signalled by a `None` `package_config`) the
    front end has already run, and `dart compile` accepts `-D` and silently
    ignores it: no error, no warning, just the default value baked into the
    output. Environment declarations for a kernel input have to go to whatever
    action produced that kernel.

    Args:
        defines: Environment declarations destined for this action.
        package_config: The `package_config.json` File, or None when `main` is
            a pre-built `.dill`.

    Returns:
        An error string, or None when the combination is sound.
    """
    if defines and package_config == None:
        return ("dart_compile_action: `defines` %s cannot be applied to a " +
                "pre-built kernel — constant evaluation already happened in " +
                "the action that produced it. Pass them to that action " +
                "instead (e.g. `gen_kernel_native_assets_action`).") % defines
    return None

def compile_quiet_flags(compile_mode):
    """Returns the flags that keep `dart compile` from writing to stdout.

    `exe` and `aot-snapshot` print `Generated: <output path>` on success, and
    Bazel echoes any action output, so every build would show a sandbox path.
    Errors still print. The other modes have no flag that silences them.

    Args:
        compile_mode: The Dart compile mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").

    Returns:
        A list of flag strings.
    """
    if compile_mode in ("exe", "aot-snapshot"):
        return ["--verbosity=error"]
    return []

def get_compilation_mode_flags(ctx, compile_mode):
    """Returns compiler flags for the current Bazel compilation mode.

    Args:
        ctx: The rule context (used to read ctx.var["COMPILATION_MODE"]).
        compile_mode: The Dart compile mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").

    Returns:
        A list of flag strings.
    """
    bazel_mode = ctx.var["COMPILATION_MODE"]

    if bazel_mode == "dbg":
        # `dart compile kernel` rejects `--enable-asserts`: a kernel file
        # retains asserts and the invoking VM decides whether to enable them
        # (dart_test's runner always passes `--enable-asserts` at runtime).
        if compile_mode == "kernel":
            return []
        return ["--enable-asserts"]
    elif bazel_mode == "opt":
        if compile_mode in ("exe", "aot-snapshot"):
            return ["--extra-gen-snapshot-options=--optimization_level=2"]
        else:
            return []
    else:
        # fastbuild: no extra flags
        return []

def dart_compile_action(
        ctx,
        dart_bin,
        sdk_files,
        main,
        srcs,
        package_config,
        output,
        compile_mode = "exe",
        target_os = "",
        target_arch = "",
        extra_flags = [],
        defines = [],
        main_path = None,
        recorded_uses = None):
    """Creates a Dart compile action.

    Args:
        ctx: The rule context.
        dart_bin: The dart executable File.
        sdk_files: Depset of all SDK files needed for the toolchain.
        main: The main File to add to action inputs. Usually the entrypoint
            `.dart` File; an assembled directory when `main_path` points inside it.
        srcs: List of all source Files needed for compilation (direct + transitive).
        package_config: The package_config.json File.
        output: The output File to produce.
        compile_mode: The compilation mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").
        target_os: Cross-compilation target OS (e.g. "linux"). Empty for native.
        target_arch: Cross-compilation target architecture (e.g. "x64"). Empty for native.
        extra_flags: Additional compiler flags (from dart_compile_flags attribute).
        defines: Environment declarations; each entry becomes a -D flag.
        main_path: Optional path string to pass as the compile target instead of
            `main.path` (e.g. a path inside an assembled `main` directory).
        recorded_uses: Optional output File for the uses of `@RecordUse`
            definitions the compiler records (`--recorded-uses`). Only the
            `exe` and `aot-snapshot` modes record; the flag works on a source
            or a kernel `main` alike.
    """
    stage_err = defines_stage_error(defines, package_config)
    if stage_err != None:
        fail(stage_err)

    args = ctx.actions.args()
    args.add("compile")
    args.add(compile_mode)
    args.add_all(compile_quiet_flags(compile_mode))

    # `package_config` is None when `main` is a pre-built kernel (`.dill`),
    # which already has package resolution baked in (e.g. the code_assets
    # path that runs gen_kernel first).
    if package_config != None:
        args.add("--packages", package_config)

    # Cross-compilation flags (only valid for exe and aot-snapshot modes)
    if target_os and (compile_mode == "exe" or compile_mode == "aot-snapshot"):
        args.add("--target-os", target_os)
    if target_arch and (compile_mode == "exe" or compile_mode == "aot-snapshot"):
        args.add("--target-arch", target_arch)

    # Compilation mode defaults
    mode_flags = get_compilation_mode_flags(ctx, compile_mode)
    args.add_all(mode_flags)

    # -D defines
    for d in defines:
        args.add("-D" + d)

    outputs = [output]
    if recorded_uses != None:
        if compile_mode not in RECORDING_COMPILE_MODES:
            fail("dart_compile_action: `dart compile %s` records no uses." % compile_mode)
        args.add(recorded_uses, format = "--recorded-uses=%s")
        outputs.append(recorded_uses)

    # Per-target extra flags (last, so they can override defaults)
    args.add_all(extra_flags)

    args.add("-o", output)
    args.add(main_path if main_path != None else main)

    env = writable_home_env(dart_bin, output)

    direct = [main] + srcs
    if package_config != None:
        direct.append(package_config)
    ctx.actions.run(
        executable = dart_bin,
        arguments = [args],
        inputs = depset(
            direct = direct,
            transitive = [sdk_files],
        ),
        outputs = outputs,
        mnemonic = "DartCompile",
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        env = env,
    )
