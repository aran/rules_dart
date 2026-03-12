"""General-purpose Dart code generation rule.

Runs a Dart script or executable as a code generator, producing .dart output
files from .dart input files. This is the Bazel-native alternative to
build_runner for simple code generation patterns.

The generator receives:
  - --input: path to the input .dart file
  - --output: path where the generated .dart file should be written
  - Any additional args from the `generator_args` attribute

Usage:
    load("@rules_dart//dart:defs.bzl", "dart_codegen")

    dart_codegen(
        name = "models_generated",
        srcs = ["user.dart", "order.dart"],
        generator = "//tools:my_generator.dart",
        output_suffix = ".g.dart",
    )

The generated files can be used as srcs in dart_library or flutter_library.

When `use_worker = True` and a .dart `generator` script is specified, actions
run through a persistent Bazel worker that amortizes Dart VM startup across
invocations (JSON worker protocol).
"""

def compute_codegen_output_name(src_path, output_suffix):
    """Compute the output file path for a codegen source file.

    Replaces the .dart extension with the given output_suffix.

    Args:
        src_path: Source file path (e.g., "some/dir/model.dart").
        output_suffix: Suffix to replace .dart (e.g., ".g.dart").

    Returns:
        The output file path (e.g., "some/dir/model.g.dart").
    """
    if src_path.endswith(".dart"):
        base = src_path[:-len(".dart")]
    else:
        base = src_path
    return base + output_suffix

def _dart_codegen_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart = toolchain.dart_sdk_info.dart
    sdk_files = toolchain.dart_sdk_info.tool_files

    if ctx.file.generator and ctx.executable.generator_bin:
        fail("Only one of 'generator' or 'generator_bin' may be specified, not both.")

    use_worker = ctx.attr.use_worker and ctx.file.generator and not ctx.executable.generator_bin

    outputs = []
    for src in ctx.files.srcs:
        # Compute output file name by replacing .dart with the output suffix.
        basename = src.basename[:-len(".dart")]
        output = ctx.actions.declare_file(
            src.dirname + "/" + basename + ctx.attr.output_suffix,
        )
        outputs.append(output)

        # Build arguments for the generator.
        args = ctx.actions.args()

        inputs = list(sdk_files) + [src]
        inputs.extend(ctx.files.data)

        if use_worker:
            # Worker mode: pass --generator so the worker knows which script to run.
            args.add("--generator", ctx.file.generator.path)
            args.add("--input", src.path)
            args.add("--output", output.path)
            args.add_all(ctx.attr.generator_args)
            inputs.append(ctx.file.generator)
            inputs.append(ctx.file._codegen_worker)

            ctx.actions.run(
                executable = dart,
                arguments = [ctx.file._codegen_worker.path, "--persistent_worker", args],
                inputs = inputs,
                outputs = [output],
                mnemonic = "DartCodegen",
                progress_message = "Generating %s from %s" % (output.short_path, src.short_path),
                execution_requirements = {
                    "supports-workers": "1",
                    "supports-worker-cancellation": "1",
                    "worker-key-mnemonic": "DartCodegen",
                },
            )
        elif ctx.executable.generator_bin:
            # Pre-compiled generator binary.
            args.add("--input", src.path)
            args.add("--output", output.path)
            args.add_all(ctx.attr.generator_args)

            ctx.actions.run(
                executable = ctx.executable.generator_bin,
                arguments = [args],
                inputs = inputs,
                outputs = [output],
                mnemonic = "DartCodegen",
                progress_message = "Generating %s from %s" % (output.short_path, src.short_path),
            )
        elif ctx.file.generator:
            # Run generator as a Dart script via the SDK's dart executable.
            args.add(ctx.file.generator.path)
            args.add("--input", src.path)
            args.add("--output", output.path)
            args.add_all(ctx.attr.generator_args)
            inputs.append(ctx.file.generator)

            ctx.actions.run(
                executable = dart,
                arguments = [args],
                inputs = inputs,
                outputs = [output],
                mnemonic = "DartCodegen",
                progress_message = "Generating %s from %s" % (output.short_path, src.short_path),
            )
        else:
            fail("Either generator or generator_bin must be specified")

    return [DefaultInfo(files = depset(outputs))]

dart_codegen = rule(
    implementation = _dart_codegen_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Input .dart source files to process.",
            mandatory = True,
            allow_files = [".dart"],
        ),
        "generator": attr.label(
            doc = "A .dart script to run as the code generator. Mutually exclusive with generator_bin.",
            allow_single_file = [".dart"],
        ),
        "generator_bin": attr.label(
            doc = "A pre-compiled generator executable. Mutually exclusive with generator.",
            executable = True,
            cfg = "exec",
        ),
        "output_suffix": attr.string(
            doc = "Suffix for generated files (replaces .dart). E.g. '.g.dart', '.freezed.dart'.",
            default = ".g.dart",
        ),
        "generator_args": attr.string_list(
            doc = "Additional arguments to pass to the generator.",
        ),
        "data": attr.label_list(
            doc = "Additional data files the generator needs as inputs.",
            allow_files = True,
        ),
        "use_worker": attr.bool(
            doc = "Use a persistent Bazel worker for .dart generator scripts. Amortizes VM startup.",
            default = False,
        ),
        "_codegen_worker": attr.label(
            doc = "The persistent codegen worker script.",
            default = "//dart/private/tools:codegen_worker.dart",
            allow_single_file = [".dart"],
        ),
    },
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs a Dart code generator on source files, producing generated .dart outputs.",
)
