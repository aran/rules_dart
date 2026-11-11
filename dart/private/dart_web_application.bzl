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
load("//dart/private:runtime.bzl", "RuntimeInfo", "web_platform_transition")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

visibility("//dart/...")

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

    carried = ctx.attr._runtime[0][RuntimeInfo].value
    if carried != compile_mode:
        fail(("%s: its `platform`, %s, carries `@rules_dart//dart/constraints:%s`, not `:%s`. " +
              "A platform a `%s` builds for must list `@rules_dart//dart/constraints:%s` in " +
              "its `constraint_values` (or name `@rules_dart//dart/platforms:%s` as a parent).") % (
            ctx.label,
            ctx.attr.platform.label,
            carried,
            compile_mode,
            "dart_js_binary" if compile_mode == "js" else "dart_wasm_binary",
            compile_mode,
            compile_mode,
        ))

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
    staged = stage_dart_project(ctx, project_layout(packages, all_srcs, [ctx.file.main] + ctx.files.srcs), dart_sdk_info)

    # The compilers write more than the program. `dart compile js` writes a
    # source map the `.js` points at (unless told not to). `dart compile wasm`
    # writes the `.mjs` loader that instantiates the module, the `.support.js`
    # feature check a page runs first, and a source map. Undeclared, Bazel
    # discards them: the `.wasm` cannot be run and the `.js` names a map that
    # is not there.
    output_groups = {}
    source_maps = "--no-source-maps" not in ctx.attr.dart_compile_flags
    if compile_mode == "js":
        output = ctx.actions.declare_file(ctx.label.name + ".js")
        if source_maps:
            output_groups["source_map"] = ctx.actions.declare_file(ctx.label.name + ".js.map")
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".wasm")
        output_groups["mjs"] = ctx.actions.declare_file(ctx.label.name + ".mjs")
        output_groups["support_js"] = ctx.actions.declare_file(ctx.label.name + ".support.js")
        if source_maps:
            output_groups["source_map"] = ctx.actions.declare_file(ctx.label.name + ".wasm.map")

    # dart2wasm names its map and its loader after the module, so it cannot
    # write the map where its sources are made relative to. With a map, it
    # compiles into a directory and `wasm_outputs` puts the files where they are
    # declared.
    two_step = compile_mode == "wasm" and source_maps
    compiled = None
    if two_step:
        compiled = ctx.actions.declare_directory(ctx.label.name + ".wasm_compiled")
        outputs = [compiled]
    else:
        outputs = [output] + output_groups.values()

    args = ctx.actions.args()
    args.add("compile")
    args.add(compile_mode)
    args.add_all(_get_web_compilation_mode_flags(ctx, compile_mode))
    for d in merge_dart_defines(ctx):
        args.add("-D" + d)
    args.add_all(ctx.attr.dart_compile_flags)
    if two_step:
        args.add_all([compiled], before_each = "-o", format_each = "%s/" + format_literal(ctx.label.name) + ".wasm", expand_directories = False)
    else:
        args.add("-o", output)

    # The entrypoint is compiled from inside the staged tree so the compiler's
    # walk-up finds the sibling .dart_tool/package_config.json.
    if compile_mode == "js":
        args.add_all([staged.src_tree], format_each = "%s/" + format_literal(ctx.file.main.short_path), expand_directories = False)
    else:
        # dart2wasm writes each source's `file:` URI into the source map. Named
        # through a multi-root scheme rooted at the action's working directory
        # (the execroot), the map holds `execroot:///bazel-out/...` instead of
        # the sandbox's absolute path, so it neither carries the user's name nor
        # differs from one machine or sandbox to the next. `source_map_relativize`
        # then makes those relative to the map, as dart2js writes them.
        args.add("-E--multi-root-scheme=execroot")
        args.add("-E--multi-root=.")
        args.add_all([staged.src_tree], format_each = "execroot:///%s/" + format_literal(ctx.file.main.short_path), expand_directories = False)

    ctx.actions.run(
        executable = dart_sdk_info.dart,
        arguments = [args],
        inputs = depset(
            direct = staged.inputs,
            transitive = [dart_sdk_info.files.dart2js if compile_mode == "js" else dart_sdk_info.files.dart2wasm],
        ),
        outputs = outputs,
        mnemonic = "DartCompileWeb",
        exec_group = PORTABLE,
        progress_message = "Compiling Dart %s %s" % (compile_mode, ctx.label),
        env = SDK_ENV,
        execution_requirements = PATH_MAPPING,
    )

    if two_step:
        finish = ctx.actions.args()
        finish.add(ctx.file._wasm_outputs)
        finish.add_all([compiled], expand_directories = False)
        finish.add(ctx.label.name)
        finish.add(output)
        finish.add(output_groups["mjs"])
        finish.add(output_groups["support_js"])
        finish.add(output_groups["source_map"])
        ctx.actions.run(
            executable = dart_sdk_info.dart,
            arguments = [finish],
            inputs = depset(
                direct = [compiled, ctx.file._wasm_outputs],
                transitive = [dart_sdk_info.files.run],
            ),
            outputs = [output] + output_groups.values(),
            mnemonic = "DartWasmOutputs",
            exec_group = PORTABLE,
            progress_message = "Placing Dart wasm outputs %s" % ctx.label,
            env = SDK_ENV,
            execution_requirements = PATH_MAPPING,
        )
        outputs = [output] + output_groups.values()

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

def _web_binary_attrs(compiler):
    return {
        "platform": attr.label(
            doc = ("The platform `deps` are built for. It must carry " +
                   "`@rules_dart//dart/constraints:{c}`; anything else on it (constraints of your own, " +
                   "`flags`) is yours. Its `os` and `cpu`, if any, are not read: the output is the same " +
                   "whichever host compiles it.").format(c = compiler),
            default = "//dart/platforms:" + compiler,
            providers = [platform_common.PlatformInfo],
        ),
        "_wasm_outputs": attr.label(
            default = "//dart/private/tools:wasm_outputs.dart",
            allow_single_file = True,
        ),
        "_runtime": attr.label(
            default = "//dart/private:target_runtime",
            cfg = web_platform_transition,
        ),
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
            doc = "`dart_library` targets this application depends on. They, and everything they depend on, are built for `platform`, so a `select()` on `@rules_dart//dart/constraints:js` or `:wasm` picks this compiler's variant.",
            providers = [DartInfo],
            cfg = web_platform_transition,
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
    attrs = _web_binary_attrs("js"),
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Compiles a Dart web application to JavaScript via `dart compile js`.\n\n" +
          "Outputs `<name>.js` and the `<name>.js.map` it points at, unless `dart_compile_flags` has " +
          "`--no-source-maps`. The map is also the `source_map` output group, so a `filegroup` can pick it out.",
)

dart_wasm_binary = rule(
    implementation = _dart_wasm_binary_impl,
    attrs = _web_binary_attrs("wasm"),
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Compiles a Dart web application to WebAssembly via `dart compile wasm`. Requires a browser with WasmGC support.\n\n" +
          "Outputs `<name>.wasm`, the `<name>.mjs` loader that instantiates it, `<name>.support.js`, and " +
          "`<name>.wasm.map` unless `dart_compile_flags` has `--no-source-maps`; the map names its " +
          "sources relative to itself, as `dart_js_binary`'s does, not by the absolute path of the sandbox that built them. Each file but the module is " +
          "also an output group (`mjs`, `support_js`, `source_map`), so a `filegroup` can pick one out.",
)
