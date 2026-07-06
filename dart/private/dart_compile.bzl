"""Shared compilation action helpers for Dart."""

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
    args = ctx.actions.args()
    args.add("compile")
    args.add(compile_mode)

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

    # Per-target extra flags (last, so they can override defaults)
    args.add_all(extra_flags)

    args.add("-o", output)
    args.add(main_path if main_path != None else main)

    # On Windows, native dart.exe receives /tmp literally (not MSYS2-translated),
    # which crashes the analysis server. Use output.dirname as a valid writable path.
    if dart_bin.basename.endswith(".exe"):
        env = {
            "USERPROFILE": output.dirname,
            "LOCALAPPDATA": output.dirname,
        }
    else:
        env = {"HOME": "/tmp"}

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
