"""Implementation of dart_js_binary and dart_wasm_binary rules.

Compiles a Dart application to JavaScript or WebAssembly for use in a browser.
`dart compile js|wasm` accepts no `--packages` flag, so the compiler resolves
packages by walking up from the entrypoint to a `.dart_tool/package_config.json`.
The rules stage that layout hermetically from declared artifacts (see
`project_staging.bzl`) and invoke the compiler directly — no shell, no mktemp.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_dart_defines")
load("//dart/private:common.bzl", "collect_packages", "collect_transitive_resources", "collect_transitive_srcs")
load("//dart/private:project_staging.bzl", "stage_dart_project")
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
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    packages = collect_packages(ctx.attr.deps)

    # Resources join the staged project for the same reason they join the
    # analyzer's: a package staged without them is not the package. They are
    # not compile inputs — `dart compile js|wasm` reads `main` and follows
    # imports — but the tree they are staged into has to be complete.
    all_srcs = ([ctx.file.main] + list(ctx.files.srcs) +
                collect_transitive_srcs(ctx.attr.deps).to_list() +
                collect_transitive_resources(ctx.attr.deps).to_list())
    staged = stage_dart_project(ctx, packages, all_srcs)

    if compile_mode == "js":
        output = ctx.actions.declare_file(ctx.label.name + ".js")
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".wasm")

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
    args.add(staged.src_tree.path + "/" + ctx.file.main.short_path)

    # Mirror dart_compile.bzl's writable-home handling (Windows dart.exe
    # receives /tmp literally and crashes).
    if dart_sdk_info.dart.basename.endswith(".exe"):
        env = {
            "USERPROFILE": output.dirname,
            "LOCALAPPDATA": output.dirname,
        }
    else:
        env = {"HOME": "/tmp"}

    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [args],
        inputs = depset(
            direct = staged.inputs,
            transitive = [dart_sdk_info.tool_files],
        ),
        outputs = [output],
        mnemonic = "DartCompileWeb",
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        env = env,
    )

    return [
        DefaultInfo(
            files = depset([output]),
        ),
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
} | EXTRA_DART_DEFINES_ATTR

dart_js_binary = rule(
    implementation = _dart_js_binary_impl,
    attrs = _WEB_BINARY_ATTRS,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles a Dart web application to JavaScript via `dart compile js`.",
)

dart_wasm_binary = rule(
    implementation = _dart_wasm_binary_impl,
    attrs = _WEB_BINARY_ATTRS,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles a Dart web application to WebAssembly via `dart compile wasm`. Requires a browser with WasmGC support.",
)
