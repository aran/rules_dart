"""Shared compilation action helpers for Dart."""

def dart_compile_action(
        ctx,
        dart_bin,
        sdk_files,
        main,
        srcs,
        package_config,
        output,
        compile_mode = "exe"):
    """Creates a Dart compile action.

    Args:
        ctx: The rule context.
        dart_bin: The dart executable File.
        sdk_files: All SDK files needed for the toolchain.
        main: The main .dart source File.
        srcs: List of all source Files needed for compilation (direct + transitive).
        package_config: The package_config.json File.
        output: The output File to produce.
        compile_mode: The compilation mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").
    """
    args = ctx.actions.args()
    args.add("compile")
    args.add(compile_mode)
    args.add("--packages", package_config)
    args.add("-o", output)
    args.add(main)

    ctx.actions.run(
        executable = dart_bin,
        arguments = [args],
        inputs = depset(
            direct = [main, package_config] + srcs,
            transitive = [depset(sdk_files)],
        ),
        outputs = [output],
        mnemonic = "DartCompile",
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        env = {
            # Prevent Dart from writing to HOME for analytics/config
            "HOME": "/tmp",
        },
    )
