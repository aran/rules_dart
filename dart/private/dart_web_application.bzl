"""Implementation of dart_js_binary and dart_wasm_binary rules.

Compiles a Dart application to JavaScript or WebAssembly for use in a browser.
`dart compile js|wasm` accepts no `--packages` flag, so the compiler resolves
packages by walking up from the entrypoint to a `.dart_tool/package_config.json`.
The rules stage that layout hermetically from declared artifacts (see
`project_staging.bzl`) and invoke the compiler directly — no shell, no mktemp.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_dart_defines")
load("//dart/private:common.bzl", "PATH_MAPPING", "SDK_ENV", "collect_transitive_resources", "collect_transitive_srcs", "format_literal")
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_sdk")
load("//dart/private:executable_package.bzl", "EXECUTABLE_PACKAGE_ATTRS", "executable_package")
load("//dart/private:project_staging.bzl", "project_layout", "stage_dart_project")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

def _get_web_compilation_mode_flags(ctx, compile_mode):
    """Returns compiler flags for the current Bazel compilation mode (web targets).

    Args:
        ctx: The rule context.
        compile_mode: "js" or "wasm".

    Returns:
        A list of flag strings.
    """
    bazel_mode = ctx.var["COMPILATION_MODE"]

    if compile_mode == "js":
        if bazel_mode == "dbg":
            return ["--enable-asserts", "-O0"]
        elif bazel_mode == "opt":
            return ["-O2"]
        else:
            return []
    else:
        # wasm
        if bazel_mode == "dbg":
            return ["--enable-asserts"]
        else:
            return []

def _dart_web_compile(ctx, compile_mode):
    """Shared compilation logic for JS and WASM web targets.

    Args:
        ctx: The rule context.
        compile_mode: "js" or "wasm".

    Returns:
        A list of providers.
    """

    # JavaScript and WebAssembly are the same whichever host compiles them.
    dart_sdk_info = portable_sdk(ctx)

    own = executable_package(ctx, [ctx.file.main] + ctx.files.srcs)
    packages = own.packages

    # Resources join the staged project for the same reason they join the
    # analyzer's: a package staged without them is not the package. They are
    # not compile inputs — `dart compile js|wasm` reads `main` and follows
    # imports — but the tree they are staged into has to be complete.
    all_srcs = ([ctx.file.main] + list(ctx.files.srcs) +
                collect_transitive_srcs(ctx.attr.deps).to_list() +
                collect_transitive_resources(ctx.attr.deps).to_list())
    staged = stage_dart_project(ctx, project_layout(packages, all_srcs, [ctx.file.main] + ctx.files.srcs))

    # `dart compile wasm` writes more than the module: the `.mjs` loader that
    # instantiates it, the `.support.js` feature check a page runs first, and
    # a source map unless told not to. Undeclared, Bazel discards them and the
    # `.wasm` cannot be run.
    output_groups = {}
    if compile_mode == "js":
        output = ctx.actions.declare_file(ctx.label.name + ".js")
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".wasm")
        output_groups["mjs"] = ctx.actions.declare_file(ctx.label.name + ".mjs")
        output_groups["support_js"] = ctx.actions.declare_file(ctx.label.name + ".support.js")
        if "--no-source-maps" not in ctx.attr.dart_compile_flags:
            output_groups["source_map"] = ctx.actions.declare_file(ctx.label.name + ".wasm.map")
    outputs = [output] + output_groups.values()

    args = ctx.actions.args()
    args.add("compile")
    args.add(compile_mode)
    args.add_all(_get_web_compilation_mode_flags(ctx, compile_mode))
    for d in merge_dart_defines(ctx):
        args.add("-D" + d)
    args.add_all(ctx.attr.dart_compile_flags)
    args.add("-o", output)

    # The entrypoint is compiled from inside the staged tree so the compiler's
    # walk-up finds the sibling .dart_tool/package_config.json.
    args.add_all([staged.src_tree], format_each = "%s/" + format_literal(ctx.file.main.short_path), expand_directories = False)

    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [args],
        inputs = depset(
            direct = staged.inputs,
            transitive = [dart_sdk_info.tool_files],
        ),
        outputs = outputs,
        mnemonic = "DartCompileWeb",
        exec_group = PORTABLE,
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        env = SDK_ENV,
        execution_requirements = PATH_MAPPING,
    )

    return [
        DefaultInfo(
            files = depset(outputs),
        ),
        OutputGroupInfo(**{k: depset([v]) for k, v in output_groups.items()}),
        # See `dart_binary`: a web entrypoint is as analyzable as a VM one, and
        # as invalid a `deps` entry.
        own.analyzable,
    ]

def _dart_js_binary_impl(ctx):
    return _dart_web_compile(ctx, "js")

def _dart_wasm_binary_impl(ctx):
    return _dart_web_compile(ctx, "wasm")

_WEB_BINARY_ATTRS = {
    "main": attr.label(
        doc = "The Dart entrypoint file containing a top-level `main()` function.",
        mandatory = True,
        allow_single_file = [".dart"],
    ),
    "srcs": attr.label_list(
        doc = "Additional Dart source files that are part of this application's package but not reachable via `deps`.",
        allow_files = [".dart"],
    ),
    "deps": attr.label_list(
        doc = "`dart_library` targets this application depends on.",
        providers = [DartInfo],
    ),
    "dart_compile_flags": attr.string_list(
        doc = "Extra flags passed to `dart compile` after compilation-mode defaults. Flags appear last so they can override defaults (e.g., `-O4` for dart2js).",
    ),
    "defines": attr.string_list(
        doc = "Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` flag.",
    ),
} | EXTRA_DART_DEFINES_ATTR | EXECUTABLE_PACKAGE_ATTRS

dart_js_binary = rule(
    implementation = _dart_js_binary_impl,
    attrs = _WEB_BINARY_ATTRS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Compiles a Dart web application to JavaScript via `dart compile js`.",
)

dart_wasm_binary = rule(
    implementation = _dart_wasm_binary_impl,
    attrs = _WEB_BINARY_ATTRS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Compiles a Dart web application to WebAssembly via `dart compile wasm`. Requires a browser with WasmGC support.\n\n" +
          "Outputs `<name>.wasm`, the `<name>.mjs` loader that instantiates it, `<name>.support.js`, and " +
          "`<name>.wasm.map` unless `dart_compile_flags` has `--no-source-maps`. Each file but the module is " +
          "also an output group (`mjs`, `support_js`, `source_map`), so a `filegroup` can pick one out.",
)
