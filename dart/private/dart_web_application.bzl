"""Implementation of dart_js_binary and dart_wasm_binary rules.

Compiles a Dart application to JavaScript or WebAssembly for use in a browser.
Uses a staging directory with .dart_tool/package_config.json for package
resolution, since `dart compile js/wasm` does not accept --packages.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "collect_packages", "collect_transitive_srcs", "generate_package_config_content", "resolve_package_roots")

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

    # Collect all transitive sources and packages
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps)
    packages = collect_packages(ctx.attr.deps)

    # Generate package_config.json with rootUri relative to .dart_tool/
    # (one level up from .dart_tool/ to project root, like dart_analyze)
    config_content = generate_package_config_content(packages, "..")
    package_config = ctx.actions.declare_file(ctx.label.name + ".web_config.json")
    ctx.actions.write(output = package_config, content = config_content)

    # Determine output extension
    if compile_mode == "js":
        output = ctx.actions.declare_file(ctx.label.name + ".js")
        staging_ext = ".js"
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".wasm")
        staging_ext = ".wasm"

    # Build symlink commands for dependency packages.
    # Use resolve_package_roots to get exec-root paths for sources,
    # and short_path lib_root for staging destinations.
    exec_roots = resolve_package_roots(packages, all_srcs)
    symlink_cmds = []
    seen_roots = {}
    for pkg in packages:
        if pkg.lib_root and pkg.lib_root not in seen_roots:
            exec_root = exec_roots.get(pkg.package_name)
            if exec_root:
                seen_roots[pkg.lib_root] = True
                symlink_cmds.append(
                    'mkdir -p "$PROJ/$(dirname {dest})" && cp -rL "$(pwd)/{src}" "$PROJ/{dest}"'.format(
                        src = exec_root,
                        dest = pkg.lib_root,
                    ),
                )

    # Symlink additional source files (srcs) into the staging directory
    for src in ctx.files.srcs:
        src_short = src.short_path
        symlink_cmds.append(
            'mkdir -p "$PROJ/$(dirname {path})" && cp "$(pwd)/{src}" "$PROJ/{path}"'.format(
                src = src.path,
                path = src_short,
            ),
        )

    # Build compilation flags
    flags = _get_web_compilation_mode_flags(ctx, compile_mode)
    for d in ctx.attr.defines:
        flags.append("-D" + d)
    flags.extend(ctx.attr.dart_compile_flags)
    flags_str = " ".join(flags)

    # Build the compilation command using a staging directory
    main_short = ctx.file.main.short_path

    cmd = """\
set -e
PROJ=$(mktemp -d)
trap 'rm -rf "$PROJ"' EXIT
export HOME="$PROJ"
export LOCALAPPDATA="$PROJ"
mkdir -p "$PROJ/.dart_tool"
cp "{config}" "$PROJ/.dart_tool/package_config.json"
{symlinks}
mkdir -p "$PROJ/$(dirname {main_short})"
cp "{main}" "$PROJ/{main_short}"
"{dart}" compile {mode} {flags} -o "$PROJ/output{ext}" "$PROJ/{main_short}"
cp "$PROJ/output{ext}" "{output}"
""".format(
        config = package_config.path,
        dart = dart_sdk_info.dart.path,
        mode = compile_mode,
        flags = flags_str,
        main = ctx.file.main.path,
        main_short = main_short,
        output = output.path,
        ext = staging_ext,
        symlinks = "\n".join(symlink_cmds),
    )

    ctx.actions.run_shell(
        command = cmd,
        inputs = [package_config, ctx.file.main, dart_sdk_info.dart] + all_srcs + list(dart_sdk_info.tool_files),
        outputs = [output],
        mnemonic = "DartCompileWeb",
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
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
}

dart_js_binary = rule(
    implementation = _dart_js_binary_impl,
    attrs = _WEB_BINARY_ATTRS,
    toolchains = ["//dart:toolchain_type"],
    doc = "Compiles a Dart web application to JavaScript via `dart compile js`.",
)

dart_wasm_binary = rule(
    implementation = _dart_wasm_binary_impl,
    attrs = _WEB_BINARY_ATTRS,
    toolchains = ["//dart:toolchain_type"],
    doc = "Compiles a Dart web application to WebAssembly via `dart compile wasm`. Requires a browser with WasmGC support.",
)
