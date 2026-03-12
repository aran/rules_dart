"""Package-level aggregate code generation rule.

Unlike per-file dart_codegen which processes each source independently,
dart_aggregate_codegen takes ALL sources in a package and produces
aggregate output. This is needed for generators like:
- auto_route (generates route maps from all annotated widgets)
- injectable (generates dependency injection containers)
- freezed (when generating union types across files)

Usage in BUILD:
    dart_aggregate_codegen(
        name = "routes",
        srcs = glob(["lib/**/*.dart"]),
        deps = [...],
        generator = "//tools:auto_route_generator",
        output = "lib/router.gr.dart",
    )
"""

load("//dart:providers.bzl", "DartInfo")

def _dart_aggregate_codegen_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    output = ctx.actions.declare_file(ctx.attr.output)

    # Collect all transitive sources for the generator to analyze.
    all_srcs = list(ctx.files.srcs)
    for dep in ctx.attr.deps:
        if DartInfo in dep:
            all_srcs.extend(dep[DartInfo].transitive_srcs.to_list())

    # Build arguments for the generator.
    args = ctx.actions.args()
    args.add("--output", output)
    for src in ctx.files.srcs:
        args.add("--input", src)
    args.add_all(ctx.attr.generator_args)

    if ctx.attr.generator_script:
        # Run a .dart script via the Dart VM.
        ctx.actions.run(
            executable = dart_sdk_info.dart,
            arguments = [ctx.file.generator_script.path, args],
            inputs = depset(
                direct = [ctx.file.generator_script] + all_srcs,
                transitive = [depset(dart_sdk_info.tool_files)],
            ),
            outputs = [output],
            mnemonic = "DartAggregateCodegen",
            progress_message = "Generating aggregate code %s" % ctx.label,
        )
    elif ctx.attr.generator:
        # Run a pre-compiled binary.
        ctx.actions.run(
            executable = ctx.executable.generator,
            arguments = [args],
            inputs = depset(direct = all_srcs),
            outputs = [output],
            mnemonic = "DartAggregateCodegen",
            progress_message = "Generating aggregate code %s" % ctx.label,
        )
    else:
        fail("Either generator or generator_script must be specified")

    return [DefaultInfo(files = depset([output]))]

dart_aggregate_codegen = rule(
    implementation = _dart_aggregate_codegen_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "All Dart source files to analyze.",
            allow_files = [".dart"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Dart library dependencies for analysis.",
        ),
        "generator": attr.label(
            doc = "Pre-compiled generator executable.",
            executable = True,
            cfg = "exec",
        ),
        "generator_script": attr.label(
            doc = "Dart script to run as the generator (via dart run).",
            allow_single_file = [".dart"],
        ),
        "output": attr.string(
            doc = "Output file path relative to the package.",
            mandatory = True,
        ),
        "generator_args": attr.string_list(
            doc = "Additional arguments to pass to the generator.",
        ),
    },
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs a package-level aggregate code generator over all sources.",
)
