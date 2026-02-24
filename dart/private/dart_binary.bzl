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
    )

    return [
        DefaultInfo(
            files = depset([output]),
            executable = output,
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
            doc = "The main Dart source file (entry point).",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart source files.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "dart_library targets this binary depends on.",
            providers = [DartInfo],
        ),
        "compile_mode": attr.string(
            doc = "The compilation mode to use.",
            default = "exe",
            values = ["exe", "aot-snapshot", "kernel", "jit-snapshot"],
        ),
    },
    executable = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Compiles a Dart application into a native executable using `dart compile`.",
)
