"""Shared compilation action helpers for Dart."""

load("//dart/private:common.bzl", "writable_home_env")

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
                "instead (e.g. `dart_kernel_action`).") % defines
    return None

_RESERVED_FRONTEND_FLAGS = [
    "--filesystem-root",
    "--filesystem-scheme",
]

_FRONTEND_ONLY_FLAGS = [
    "--define",
    "--embed-sources",
    "--enable-experiment",
    "--link-platform",
    "--no-embed-sources",
    "--no-link-platform",
]

_FRONTEND_AND_BACKEND_FLAGS = [
    "--enable-asserts",
    "--no-enable-asserts",
    "--verbosity",
]

def _long_flag_name(flag):
    return flag.split("=", 1)[0]

def split_dart_compile_flags(flags):
    """Routes user flags to the source frontend and/or kernel backend.

    The stable multi-root mapping is an invariant of the action and cannot be
    replaced through `dart_compile_flags`. Language experiments, source
    embedding, environment declarations written as raw flags, and other
    frontend options must run before the kernel exists. Backend-specific flags
    retain their old position at the end of `dart compile`'s argv.

    Args:
      flags: The `dart_compile_flags` string list.

    Returns:
      `struct(frontend, backend)`.
    """
    frontend = []
    backend = []
    frontend_value = False
    both_value = False
    for flag in flags:
        if frontend_value:
            frontend.append(flag)
            frontend_value = False
            continue
        if both_value:
            frontend.append(flag)
            backend.append(flag)
            both_value = False
            continue

        name = _long_flag_name(flag)
        if name in _RESERVED_FRONTEND_FLAGS:
            fail(("dart_compile_flags may not set %s: rules_dart reserves the " +
                  "execroot filesystem mapping so compiled source URIs remain " +
                  "deterministic.") % name)

        # `-Dfoo=bar` is the short spelling of `--define=foo=bar`.
        if flag == "-D" or (flag.startswith("-D") and len(flag) > 2):
            frontend.append(flag)
            frontend_value = flag == "-D"
        elif name in _FRONTEND_ONLY_FLAGS:
            frontend.append(flag)
            frontend_value = "=" not in flag and name in ["--define", "--enable-experiment"]
        elif name in _FRONTEND_AND_BACKEND_FLAGS:
            frontend.append(flag)
            backend.append(flag)
            both_value = "=" not in flag and name == "--verbosity"
        else:
            backend.append(flag)
    return struct(frontend = frontend, backend = backend)

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
        main_path = None):
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
    """
    stage_err = defines_stage_error(defines, package_config)
    if stage_err != None:
        fail(stage_err)

    args = ctx.actions.args()
    args.add("compile")
    args.add(compile_mode)

    # `package_config` is None when `main` is a pre-built kernel (`.dill`),
    # which already has package resolution baked in by the stable frontend.
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
        outputs = [output],
        mnemonic = "DartCompile",
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        env = env,
    )
