"""Implementation of dart_js_binary and dart_wasm_binary rules.

Compiles a Dart application to JavaScript or WebAssembly for use in a browser.
Uses a staging directory with .dart_tool/package_config.json for package
resolution, since `dart compile js/wasm` does not accept --packages.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "collect_packages", "collect_transitive_srcs", "generate_package_config_content")

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

    # Build symlink commands for dependency packages
    symlink_cmds = []
    seen_roots = {}
    for pkg in packages:
        if pkg.lib_root and pkg.lib_root not in seen_roots:
            seen_roots[pkg.lib_root] = True
            symlink_cmds.append(
                'mkdir -p "$PROJ/$(dirname {root})" && ln -s "$(pwd)/{root}" "$PROJ/{root}"'.format(root = pkg.lib_root),
            )

    # Symlink additional source files (srcs) into the staging directory
    for src in ctx.files.srcs:
        src_short = src.short_path
        symlink_cmds.append(
            'mkdir -p "$PROJ/$(dirname {path})" && ln -sf "$(pwd)/{src}" "$PROJ/{path}"'.format(
                src = src.path,
                path = src_short,
            ),
        )

    # Build the compilation command using a staging directory
    main_short = ctx.file.main.short_path

    cmd = """\
set -e
PROJ=$(mktemp -d)
trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/.dart_tool"
cp "{config}" "$PROJ/.dart_tool/package_config.json"
{symlinks}
mkdir -p "$PROJ/$(dirname {main_short})"
cp "{main}" "$PROJ/{main_short}"
"{dart}" compile {mode} -o "$PROJ/output{ext}" "$PROJ/{main_short}"
cp "$PROJ/output{ext}" "{output}"
""".format(
        config = package_config.path,
        dart = dart_sdk_info.dart.path,
        mode = compile_mode,
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
        env = {"HOME": "/tmp"},
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
