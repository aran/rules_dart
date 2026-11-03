"""Shared compilation action helpers for Dart."""

load("//dart/private:common.bzl", "PATH_MAPPING", "SDK_ENV")
load("//dart/private:resources.bzl", "native_compile_resources")

_DART_TOOLCHAIN = Label("//dart:toolchain_type")

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
    front end has already run. They go to that action instead. `--verbosity`
    filters the messages of both steps, so it goes to both.

    A flag given its value as the next element (`["-D", "A=1"]`) takes that
    element with it.

    Args:
        flags: The `dart_compile_flags` list.

    Returns:
        `(front_end, rest)`, each a list in the original order.
    """
    front_end = []
    rest = []
    pending = None
    for f in flags:
        if pending != None:
            for dest in pending:
                dest.append(f)
            pending = None
            continue
        if f.startswith("--verbosity"):
            dests = [front_end, rest]
        elif f.startswith("--enable-experiment") or f.startswith("-D") or f.startswith("--define"):
            dests = [front_end]
        else:
            rest.append(f)
            continue
        for dest in dests:
            dest.append(f)
        if f in ("-D", "--define", "--enable-experiment", "--verbosity"):
            pending = dests
    return front_end, rest

def dart_compile_action(
        ctx,
        sdk,
        kernel,
        output,
        compile_mode = "exe",
        extra_flags = [],
        recorded_uses = None,
        runner = None):
    """Creates the `dart compile` action that turns a kernel into the output.

    The kernel comes from `dart_kernel_action`, which has already run the front
    end, so nothing here resolves packages or folds constants: no
    `--packages`, no `-D`.

    Args:
        ctx: The rule context.
        sdk: The target toolchain's `DartSdkInfo`. A cross toolchain's
            `target_os`/`target_arch` and `cross_tools` make it a cross compile.
        kernel: The `.dill` File to compile.
        output: The output File to produce.
        compile_mode: The compilation mode ("exe", "aot-snapshot", "jit-snapshot").
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
    if sdk.target_os and (compile_mode == "exe" or compile_mode == "aot-snapshot"):
        args.add("--target-os", sdk.target_os)
    if sdk.target_arch and (compile_mode == "exe" or compile_mode == "aot-snapshot"):
        args.add("--target-arch", sdk.target_arch)

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
        runner_args.add(sdk.dart)
        arguments = [runner_args, args]
        direct = [kernel, runner]
    else:
        arguments = [args]
        direct = [kernel]

    env = dict(SDK_ENV)
    transitive = [sdk.tool_files]
    if sdk.cross_tools != None and compile_mode in RECORDING_COMPILE_MODES:
        # The modes that take the target flags. dartdev reads only this cache
        # from the home it is given, so a read-only one serves.
        env["APPDATA" if sdk.exec_os == "windows" else "HOME"] = sdk.cross_tools.home
        transitive.append(sdk.cross_tools.files)

    ctx.actions.run(
        executable = sdk.dart,
        arguments = arguments,
        inputs = depset(direct = direct, transitive = transitive),
        outputs = outputs,
        mnemonic = "DartCompile",
        # `sdk` is the target toolchain's: machine code for the target.
        toolchain = _DART_TOOLCHAIN,
        resource_set = native_compile_resources,
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        env = env,
        execution_requirements = PATH_MAPPING,
    )
