"""Implementation of the dart_binary rule."""

load("//dart:providers.bzl", "DartCompileInfo", "DartInfo")
load("//dart/private:common.bzl", "collect_packages", "collect_transitive_srcs", "generate_package_config_content")
load("//dart/private:dart_compile.bzl", "dart_compile_action")

def _generate_package_config(ctx, deps):
    """Generate a package_config.json from the transitive DartInfo deps."""
    packages = collect_packages(deps)
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")

    # The config file is in the output tree (e.g. bazel-out/.../bin/app/).
    # Sources are in the source tree (e.g. greeter/lib/).
    # Compute relative path from the config file back to the execroot.
    depth = len(package_config.dirname.split("/"))
    prefix = "/".join([".."] * depth)

    content = generate_package_config_content(packages, prefix)
    ctx.actions.write(output = package_config, content = content)
    return package_config

def _dart_binary_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # Collect all transitive sources from deps
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps)

    # Generate package_config.json
    package_config = _generate_package_config(ctx, ctx.attr.deps)

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

    # Run dart compile
    dart_compile_action(
        ctx = ctx,
        dart_bin = dart_sdk_info.dart,
        sdk_files = dart_sdk_info.tool_files,
        main = ctx.file.main,
        srcs = all_srcs,
        package_config = package_config,
        output = output,
        compile_mode = compile_mode,
        target_os = dart_sdk_info.target_os,
        target_arch = dart_sdk_info.target_arch,
        extra_flags = ctx.attr.dart_compile_flags,
        defines = ctx.attr.defines,
    )

    runfiles = ctx.runfiles(files = ctx.files.data)

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
    attrs = {
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
    },
    executable = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Compiles a Dart application using `dart compile`.",
)
