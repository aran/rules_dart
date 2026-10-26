"""Shared compilation action helpers for Dart."""

load("//dart/private:common.bzl", "sdk_home")
load("//dart/private:resources.bzl", "native_compile_resources")

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
        compile_mode: The Dart compile mode ("exe", "aot-snapshot", "jit-snapshot").
            A `kernel` is the front end's output itself and never reaches
            `dart compile`; it keeps its asserts, and the VM that runs it
            decides whether to enable them.

    Returns:
        A list of flag strings.
    """
    bazel_mode = ctx.var["COMPILATION_MODE"]

    if bazel_mode == "dbg":
        return ["--enable-asserts"]
    elif bazel_mode == "opt":
        if compile_mode in ("exe", "aot-snapshot"):
            return ["--extra-gen-snapshot-options=--optimization_level=2"]
        else:
            return []
    else:
        # fastbuild: no extra flags
        return []

def front_end_flags(flags):
    """Splits `dart compile` flags into those for the front end and the rest.

    `dart compile` runs the front end itself when given source, so a user flag
    meant for it (`--enable-experiment`, a `-D` define) worked there. Given the
    kernel `dart_kernel_action` produced, it accepts them and ignores them: the
    front end has already run. They go to that action instead.

    Args:
        flags: The `dart_compile_flags` list.

    Returns:
        `(front_end, rest)`, each a list in the original order.
    """
    front_end = []
    rest = []
    for f in flags:
        if f.startswith("--enable-experiment") or f.startswith("-D") or f.startswith("--define"):
            front_end.append(f)
        else:
            rest.append(f)
    return front_end, rest

def dart_compile_action(
        ctx,
        dart_bin,
        sdk_files,
        kernel,
        output,
        compile_mode = "exe",
        target_os = "",
        target_arch = "",
        extra_flags = [],
        recorded_uses = None,
        runner = None):
    """Creates the `dart compile` action that turns a kernel into the output.

    The kernel comes from `dart_kernel_action`, which has already run the front
    end, so nothing here resolves packages or folds constants: no
    `--packages`, no `-D`.

    Args:
        ctx: The rule context.
        dart_bin: The dart executable File.
        sdk_files: Depset of all SDK files needed for the toolchain.
        kernel: The `.dill` File to compile.
        output: The output File to produce.
        compile_mode: The compilation mode ("exe", "aot-snapshot", "jit-snapshot").
        target_os: Cross-compilation target OS (e.g. "linux"). Empty for native.
        target_arch: Cross-compilation target architecture (e.g. "x64"). Empty for native.
        extra_flags: Additional compiler flags (from dart_compile_flags attribute).
        recorded_uses: Optional output File for the uses of `@RecordUse`
            definitions the compiler records (`--recorded-uses`). Only the
            `exe` and `aot-snapshot` modes record.
        runner: Optional `compile_runner` kernel File to compile through. For a
            Mach-O `exe` or `aot-snapshot`, whose symbol table names the path
            gen_snapshot wrote the snapshot to: the runner picks that path and
            then removes it (see `compile_runner.dart`).
    """
    args = ctx.actions.args()
    args.add("compile")
    args.add(compile_mode)
    args.add_all(compile_quiet_flags(compile_mode))

    # Cross-compilation flags (only valid for exe and aot-snapshot modes)
    if target_os and (compile_mode == "exe" or compile_mode == "aot-snapshot"):
        args.add("--target-os", target_os)
    if target_arch and (compile_mode == "exe" or compile_mode == "aot-snapshot"):
        args.add("--target-arch", target_arch)

    # Compilation mode defaults
    mode_flags = get_compilation_mode_flags(ctx, compile_mode)
    args.add_all(mode_flags)

    outputs = [output]
    if recorded_uses != None:
        if compile_mode not in RECORDING_COMPILE_MODES:
            fail("dart_compile_action: `dart compile %s` records no uses." % compile_mode)
        args.add(recorded_uses, format = "--recorded-uses=%s")
        outputs.append(recorded_uses)

    # Per-target extra flags (last, so they can override defaults)
    args.add_all(extra_flags)

    # Through the runner, the command follows its own arguments, and the runner
    # gives `-o` itself. Otherwise `-o` precedes the kernel: `jit-snapshot`
    # hands everything after it to the training run.
    if runner == None:
        args.add("-o", output)
    args.add(kernel)

    if runner != None:
        runner_args = ctx.actions.args()
        runner_args.add(runner)
        runner_args.add("--output", output)
        runner_args.add("--")
        runner_args.add(dart_bin)
        arguments = [runner_args, args]
        direct = [kernel, runner]
    else:
        arguments = [args]
        direct = [kernel]

    ctx.actions.run(
        executable = dart_bin,
        arguments = arguments,
        inputs = depset(direct = direct, transitive = [sdk_files]),
        outputs = outputs,
        mnemonic = "DartCompile",
        resource_set = native_compile_resources,
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        **sdk_home(dart_bin, output)
    )
