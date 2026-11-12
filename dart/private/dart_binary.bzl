"""Implementation of the dart_binary rule."""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartCompileInfo", "DartInfo", "DartRecordedUsesInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "SPLIT_DEBUG_INFO_ATTR", "TRACK_CREATION_LOCATIONS_ATTR", "merge_dart_defines", "split_debug_info", "track_creation_locations")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "EMPTY_PACKAGE_CONFIG_ATTR",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_transitive_resources",
    "collect_transitive_runfiles",
    "empty_package_config",
    "generate_native_assets_yaml",
    "launcher_executable",
    "runfiles_path",
    "stage_code_assets",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "compile_kernel_file", "dart_compile_action", "front_end_flags", "get_compilation_mode_flags", "recorded_uses_kind")
load("//dart/private:dart_import_check.bzl", "dart_import_check_aspect", "import_check_output_groups", "without_import_check")
load("//dart/private:dart_module.bzl", "KERNEL_TOOL_ATTR", "PROGRAM_KERNEL_SDK_ATTR", "whole_program_kernel")
load("//dart/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//dart/private:executable_package.bzl", "EXECUTABLE_PACKAGE_ATTRS", "executable_package")
load("//dart/private:program_assets.bzl", "UNLINKED_PROGRAM_ASSETS_ATTRS", "UNLINKED_PROGRAM_ASSETS_TOOLCHAINS", "dart_program_assets_actions", "program_kernel_code_assets")
load("//dart/private:runtime.bzl", "dart_tool_reset")

visibility("//dart/...")

def binary_output_basename(name, compile_mode, is_windows):
    """Returns a `dart_binary`'s output filename with the platform exe extension.

    Includes the platform-appropriate executable extension.

    A native `exe` gets a `.exe` suffix on Windows so it is launchable and
    discoverable by the conventional name (e.g. via runfiles
    `rlocation("…/app.exe")`). Without it the output is a bare `app`, and a
    consumer looking up `app.exe` misses — falling through to a non-existent
    path. The snapshot modes use fixed extensions on every platform.

    Args:
      name: The target name (`ctx.label.name`).
      compile_mode: One of `exe`, `aot-snapshot`, `kernel`.
      is_windows: Whether the target platform is Windows.

    Returns:
      The output filename string.
    """
    if compile_mode == "exe":
        return name + (".exe" if is_windows else "")
    elif compile_mode == "aot-snapshot":
        return name + ".aot"
    elif compile_mode == "kernel":
        return name + ".dill"
    fail("Unknown compile_mode: %s" % compile_mode)

def _dart_binary_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    own = executable_package(ctx, [ctx.file.main] + ctx.files.srcs)
    packages = own.packages

    if ctx.attr.code_assets_from_packages:
        hook_err = check_unreplaced_hooks(ctx.label, packages)
        if hook_err != None:
            fail(hook_err)

    # Determine output filename (Windows gets the `.exe` extension — see
    # `binary_output_basename`).
    compile_mode = ctx.attr.compile_mode
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._os_windows[platform_common.ConstraintValueInfo],
    )
    output = ctx.actions.declare_file(
        binary_output_basename(ctx.label.name, compile_mode, is_windows),
    )

    # Two steps for every mode: the front end produces a kernel, read through a
    # filesystem rooted at the exec root so the output does not depend on where
    # the action ran (see `dart_kernel_action`), and `dart compile` turns it
    # into the requested output. A `kernel` is the first step's output itself.
    defines = merge_dart_defines(ctx)
    for f in ctx.attr.dart_compile_flags:
        if "--resolve-dwarf-paths" in f or "--resolve_dwarf_paths" in f:
            fail(("%s: `--resolve-dwarf-paths` cannot be used: the kernel names each source " +
                  "`org-dartlang-root:///<path in the workspace>`, never a path on disk, so the " +
                  "build is the same everywhere, and gen_snapshot converts only `file:` URIs. " +
                  "Leave it out: DWARF then names each source by that URI, whose path is the " +
                  "file's in the workspace (`external/<repo>/...` for another repository's).") % ctx.label)
        if f == "-S" or f.startswith("--save-debugging-info"):
            fail(("%s: `%s` cannot be used: the file it writes is not an output Bazel knows " +
                  "of, so it is lost. Build with `--@rules_dart//dart:split_debug_info`, which " +
                  "writes `%s.symbols` in the `debug_info` output group.") % (ctx.label, f, ctx.label.name))
    fe_flags, compile_flags = front_end_flags(ctx.attr.dart_compile_flags)
    code_asset_libs = []

    # What the binary loads is what its program ships, not linked: the assets
    # of any of its packages, its own or one in `deps` (the upstream semantics —
    # depending on a package gets you its assets), and those named outright, for
    # hand-written cases. The mapping is embedded in the kernel, its `relative`
    # paths resolved against the final executable at run time: each library is
    # linked into `<name>.native/` beside it, so the path holds wherever the
    # executable and that directory go together.
    resolved_assets = program_kernel_code_assets(dart_program_assets_actions(
        ctx,
        package = own.record if ctx.attr.code_assets_from_packages else None,
        deps = ctx.attr.deps if ctx.attr.code_assets_from_packages else [],
        # Beside the executable, `<name>`, which no directory may share.
        name = ctx.label.name + ".program",
        code_assets = [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    ).info)
    native_assets_yaml = None
    if resolved_assets:
        abi = target_dart_abi(ctx)
        entries, code_asset_libs = code_asset_entries(
            ctx.label,
            _stage_libraries(ctx, resolved_assets),
            output.dirname,
        )
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(abi, entries),
        )

    kernel = output if compile_mode == "kernel" else compile_kernel_file(ctx)
    whole_program_kernel(
        ctx,
        main = ctx.file.main,
        packages = packages,
        output_dill = kernel,
        defines = defines,
        # A `kernel` has no second step, so every flag belongs to the first.
        flags = ctx.attr.dart_compile_flags if compile_mode == "kernel" else fe_flags,
        native_assets_yaml = native_assets_yaml,
        track_creation_locations = track_creation_locations(ctx),
    )

    # The compiler records the uses of `@RecordUse` definitions only when it
    # tree-shakes, so the other modes get the file it writes when there is
    # nothing to record: a link hook then runs over no uses, as for a program
    # that uses none.
    compile_recorded_uses = None
    recorded_uses_info = []
    if ctx.attr.record_use:
        recorded_uses = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json")
        kind = recorded_uses_kind(compile_mode)
        if kind == "aot":
            compile_recorded_uses = recorded_uses
        else:
            ctx.actions.write(output = recorded_uses, content = "{}")
        recorded_uses_info = [DartRecordedUsesInfo(
            file = recorded_uses,
            kind = kind,
            package = own.record.metadata if own.record != None else None,
            package_files = own.package_files,
        )]

    debug_info = None
    if compile_mode != "kernel" and split_debug_info(ctx):
        debug_info = ctx.actions.declare_file(ctx.label.name + ".symbols")

    if compile_mode != "kernel":
        dart_compile_action(
            ctx = ctx,
            sdk = dart_sdk_info,
            kernel = kernel,
            output = output,
            compile_mode = compile_mode,
            extra_flags = compile_flags,
            recorded_uses = compile_recorded_uses,
            debug_info = debug_info,
            runner = _compile_runner(ctx, compile_mode),
        )

    # Resources ride the runfiles, not the compile. A dep's `lib/**` non-Dart
    # files are part of the package at run time under pub, and the compiled
    # binary is the one place that cannot recover them: `Isolate.resolvePackageUri`
    # returns null in an AOT binary with no package_config above it, so a
    # package cannot read its own shipped files back out. Staging them here is
    # what makes `rlocation` work for them.
    runfiles = ctx.runfiles(
        files = ctx.files.data + code_asset_libs,
        transitive_files = collect_transitive_resources(ctx.attr.deps),
    ).merge_all(
        [dep[DefaultInfo].default_runfiles for dep in ctx.attr.data] +
        [collect_transitive_runfiles(ctx, ctx.attr.deps)],
    )
    executable = output
    launcher = _launcher(ctx, dart_sdk_info, compile_mode, output)
    if launcher != None:
        executable = launcher.executable
        runfiles = runfiles.merge(launcher.runfiles)

    return [
        DefaultInfo(
            files = depset([output] + code_asset_libs),
            executable = executable,
            runfiles = runfiles,
        ),
        DartCompileInfo(
            executable = output,
            compile_mode = compile_mode,
        ),
        # What makes the `dart_analyze` aspect reach this entrypoint without
        # making this target a legal `deps` entry.
        own.analyzable,
        OutputGroupInfo(
            debug_info = depset([debug_info] if debug_info != None else []),
            **_import_checks(ctx, own)
        ),
    ] + recorded_uses_info

def _stage_libraries(ctx, assets):
    directory = ctx.label.name + ".native"
    owners = {}
    for asset in assets:
        library = asset.file
        if library == None:
            continue
        previous = owners.get(library.basename)
        if previous and previous[0] != library:
            fail("%s: code assets %s and %s both have a library named %s, and a binary's libraries share one directory" % (
                ctx.label,
                previous[1],
                asset.asset_id,
                library.basename,
            ))
        owners[library.basename] = (library, asset.asset_id)
    return stage_code_assets(ctx, assets, lambda _index: directory)

def _launcher(ctx, sdk, compile_mode, output):
    """The executable that runs a snapshot or kernel `output` in its VM.

    Returns None where `output` is itself the executable (`exe`), and where
    this build has no VM for the target: a cross toolchain's SDK runs on the
    host, so a cross-compiled snapshot is run with the target's runtime there.
    """
    if compile_mode == "exe" or not hasattr(ctx.attr, "_launcher") or sdk.target_os:
        return None
    dart = runfiles_path(sdk.dart, ctx.workspace_name)
    if compile_mode == "aot-snapshot":
        vm = dart.rpartition("/")[0] + "/dartaotruntime" + (".exe" if dart.endswith(".exe") else "")
    else:
        vm = dart

    # A kernel keeps its asserts for the VM that runs it to enable, which is
    # this launcher; an AOT snapshot was compiled with them or without. An
    # empty package config stops the VM looking for one up from the program,
    # where outside a sandbox it finds the workspace's own `.dart_tool`
    # through the exec root.
    packages = empty_package_config(ctx)
    flags = [{"rlocation": runfiles_path(packages, ctx.workspace_name), "prefix": "--packages="}]
    flags += get_compilation_mode_flags(ctx, "kernel") if compile_mode == "kernel" else []
    launcher = launcher_executable(ctx, ctx.attr._launcher)
    config = ctx.actions.declare_file(ctx.label.name + ".launcher.json")
    ctx.actions.write(
        output = config,
        content = json.encode({
            "executable": vm,
            "arguments": flags + [{"rlocation": runfiles_path(output, ctx.workspace_name)}],
        }),
    )
    return struct(
        executable = launcher.executable,
        runfiles = ctx.runfiles(
            files = [output, config, packages],
            transitive_files = sdk.files.aot_run if compile_mode == "aot-snapshot" else sdk.files.run,
        ).merge(launcher.runfiles),
    )

def _compile_runner(ctx, compile_mode):
    # Only gen_snapshot's Mach-O output names where it was written.
    if not hasattr(ctx.attr, "_compile_runner") or compile_mode not in ("exe", "aot-snapshot"):
        return None
    if not ctx.target_platform_has_constraint(ctx.attr._os_macos[platform_common.ConstraintValueInfo]):
        return None
    return ctx.file._compile_runner

def _import_checks(ctx, own):
    # `dart_tool_binary` has no `kernel_tool` to check with: it builds it.
    if not hasattr(ctx.attr, "_kernel_tool"):
        return {}
    return import_check_output_groups(
        ctx,
        ctx.executable._kernel_tool,
        [ctx.file.main] + ctx.files.srcs,
        own.record,
        ctx.attr.deps,
    )

_COMPILE_RUNNER_ATTR = {
    "_compile_runner": attr.label(
        default = "//dart/private/tools:compile_runner",
        allow_single_file = True,
        cfg = "exec",
    ),
}

_LAUNCHER_ATTR = {
    "_launcher": attr.label(
        default = "//dart/private/tools:launcher",
        executable = True,
        cfg = "target",
    ),
} | EMPTY_PACKAGE_CONFIG_ATTR

def _dart_binary_rule(check_imports, compile_runner = True, launcher = True):
    return rule(
        implementation = _dart_binary_impl,
        attrs = dict(
            dict(KERNEL_TOOL_ATTR, **PROGRAM_KERNEL_SDK_ATTR) if check_imports else {},
            **dict(_COMPILE_RUNNER_ATTR if compile_runner else {}, **dict(_LAUNCHER_ATTR if launcher else {}, **dict({
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
                    aspects = [dart_import_check_aspect] if check_imports else [],
                    # A tool built without the check is one the check runs on,
                    # `kernel_tool`: its libraries cannot depend on it.
                    cfg = "target" if check_imports else without_import_check,
                ),
                "data": attr.label_list(
                    doc = "Additional files needed at runtime. These are added to runfiles so they can be found via the runfiles tree when using `bazel run`.",
                    allow_files = True,
                ),
                "code_assets": attr.label_list(
                    doc = """Native code assets (e.g. `//dart/ext/sqlite3:code_asset`) the binary's \
    `@Native` FFI bindings resolve against. When set, the main is compiled to a kernel with the \
    code-asset mapping embedded (`frontend_server --native-assets`) before the snapshot/exe is produced, \
    and the libraries are linked into `<name>.native/` beside the executable, where the Dart VM \
    finds them at runtime: to install the binary, copy the executable and that directory together, following links (`cp -RL`), because the files there are symlinks into the output tree. Each entry must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule). An entry replaces the asset with the same id that `deps` supply, so a binary can load a differently built library under that id.""",
                    providers = [DartCodeAssetInfo],
                ),
                "code_assets_from_packages": attr.bool(
                    default = True,
                    doc = """Whether to pick up the native code assets the binary's packages declare: its own \
    `package`'s and those of every package `deps` reach.

    Leave this on for a program that runs the packages it depends on. Turn it off for a `dart_binary` \
    used purely as a *build tool* — a code generator, a linter — which imports pub packages for their \
    Dart API but never loads their native libraries. Without the opt-out such a tool would build (and \
    in an exec configuration, cross-build) every native library anywhere in its dependency closure. \
    rules_dart's own `dart/ext` builder shims set this to `False`: `drift_dev` depends on \
    `package:sqlite3`, but generating code never calls into libsqlite3.

    Also suppresses the unreplaced-`hook/build.dart` diagnostic, on the same grounds — a tool that \
    never loads native code is unaffected by a package whose native code was not built.""",
                ),
                "compile_mode": attr.string(
                    doc = """\
    The `dart compile` mode. Determines the output format:

    - `exe` (default): Self-contained native machine code. No Dart SDK needed at runtime. Best for deployment.
    - `aot-snapshot`: AOT-compiled snapshot. Requires `dartaotruntime` to execute. Smaller than `exe`.
    - `kernel`: Dart kernel binary (`.dill`). Requires `dart` to execute. Fastest compilation, useful for development.

    In the last two modes the output is `<name>.aot` or `<name>.dill`, and the target's executable is a \
    launcher that runs it in the SDK's VM, so the target works with `bazel run` and as another target's `data`. A \
    cross-compiled output has no VM for its target here and is its own executable.

    With `--@rules_dart//dart:split_debug_info`, an `exe` or `aot-snapshot` leaves its debugging \
    information out and writes it to `<name>.symbols`, in the `debug_info` output group.
    """,
                    default = "exe",
                    values = ["exe", "aot-snapshot", "kernel"],
                ),
                "dart_compile_flags": attr.string_list(
                    doc = "Extra flags passed to `dart compile` after compilation-mode defaults. Flags appear last so they can override defaults (e.g., `--extra-gen-snapshot-options=--optimization_level=3`). Front-end flags (`--enable-experiment`, `-D`/`--define`) go to the front-end step that precedes `dart compile`, and `--verbosity` to both; in the `kernel` mode, which is that step alone, every flag does, and only those `frontend_server` accepts work. `--extra-gen-snapshot-options=--resolve-dwarf-paths` is refused: sources are named by workspace-relative `org-dartlang-root:///` URIs, which gen_snapshot cannot turn into paths, and DWARF without it names them by those URIs. `--save-debugging-info` (`-S`) is refused: `--@rules_dart//dart:split_debug_info` writes that file as an output.",
                ),
                "defines": attr.string_list(
                    doc = "Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` flag.",
                ),
                "record_use": attr.bool(
                    doc = """Record the uses of `@RecordUse` definitions (`package:meta`) as \
    `<name>.recorded_uses.json`, provided as `DartRecordedUsesInfo` for `dart_program_assets`. \
    In the `exe` and `aot-snapshot` modes the compiler records them as it tree-shakes. The \
    `kernel` mode does not tree-shake, so nothing is recorded and the file is \
    the empty JSON object `{}` (`kind = "empty"`).""",
                ),
            }, **dict(DART_ABI_CONSTRAINT_ATTRS, **dict(EXTRA_DART_DEFINES_ATTR, **dict(TRACK_CREATION_LOCATIONS_ATTR, **dict(SPLIT_DEBUG_INFO_ATTR, **dict(UNLINKED_PROGRAM_ASSETS_ATTRS, **EXECUTABLE_PACKAGE_ATTRS))))))))
        ),
        executable = True,
        # rules_dart's own tools are the same program in every build that
        # reaches them: they drop the settings of the build they are reached
        # from that `bootstrap_kernel_action` cannot honour.
        cfg = None if check_imports else dart_tool_reset,
        # The default group compiles machine code for the target, so its SDK
        # matches the target; the kernel before it is `portable`.
        toolchains = ["//dart:toolchain_type"] + UNLINKED_PROGRAM_ASSETS_TOOLCHAINS,
        # The C++ toolchain links the native code a package links into each
        # program (`linked_code_assets`).
        fragments = ["cpp"],
        exec_groups = PORTABLE_EXEC_GROUPS,
        doc = "Compiles a Dart application using `dart compile`.",
    )

dart_binary = _dart_binary_rule(check_imports = True)

# `kernel_tool` itself, which checks everyone else's imports, and the
# `launcher` of the other modes: built without the check, which would depend on
# `kernel_tool`, and without a launcher, which would depend on itself. Only for
# rules_dart's own `exe` tools.
dart_tool_binary = _dart_binary_rule(check_imports = False, launcher = False)

# `compile_runner`, which every macOS `exe` and `aot-snapshot` compiles
# through: a `kernel`, which does not, built by a rule that does not depend on
# it. Goes when `compile_runner` does (see its header). Its action runs it with
# the SDK's `dart`, so it needs no launcher.
dart_bootstrap_binary = _dart_binary_rule(check_imports = False, compile_runner = False, launcher = False)
