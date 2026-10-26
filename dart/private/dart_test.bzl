"""Implementation of the dart_test rule.

The test is compiled to a self-contained kernel (`.dill`) **at build time** and
the launcher merely runs it, so no sources and no `package_config` are needed at
run time and manifest-mode runfiles (Windows) are a non-issue. Its dependencies
are compiled once each, into the kernel modules `dart_module_aspect` builds;
the test compiles only its own files against them and links the program (see
`dart_module.bzl`).
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartKernelSdkInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_vm_dart_defines")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_transitive_code_assets",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "dart_kernel_action",
    "generate_native_assets_yaml",
    "relative_path",
    "resolve_code_assets",
    "runfiles_path",
    "stage_code_assets",
    "target_dart_abi",
    "test_executable",
)
load("//dart/private:dart_import_check.bzl", "dart_import_check_aspect", "import_check_validation")
load(
    "//dart/private:dart_module.bzl",
    "MODULE_EXECUTABLE_ATTRS",
    "collect_modules",
    "dart_entry_kernel_action",
    "dart_link_kernel_action",
    "kernel_package_config",
    "kernel_root_path",
    "kernel_roots",
    "module_defines_transition",
    "vm_module_aspect",
)
load("//dart/private:dart_test_runner.bzl", "DartTestRunnerInfo")
load("//dart/private:exec_groups.bzl", "EXEC_TOOLS_TOOLCHAIN", "PORTABLE_EXEC_GROUPS")
load("//dart/private:executable_package.bzl", "EXECUTABLE_PACKAGE_ATTRS", "executable_package")

def _dart_test_impl(ctx):
    # The VM that runs the test, built for the host the test runs on.
    dart_sdk_info = ctx.exec_groups["test"].toolchains[EXEC_TOOLS_TOOLCHAIN].dart_sdk_info
    workspace_name = ctx.workspace_name
    sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo]

    own = executable_package(ctx, [ctx.file.main] + ctx.files.srcs)
    packages = own.packages
    runner = _test_runner(ctx, packages)

    hook_err = check_unreplaced_hooks(ctx.label, packages)
    if hook_err != None:
        fail(hook_err)

    # The test's own files compile as a module of their own; the entrypoint
    # compiled against them is generated: the `package:test` bootstrap, or a
    # forwarder to the test's `main`.
    main = _write_bootstrap(ctx) if runner else _write_forwarder(ctx)

    if runner:
        # Declared where the runner's `--precompiled` layout expects it, so it
        # is loaded in place: code-asset paths are relative to the dill, and a
        # copy elsewhere would leave them pointing at nothing.
        dill = ctx.actions.declare_file(
            "%s.precompiled/%s.vm_test.vm.app.dill" % (ctx.label.name, _test_path(ctx)),
        )
    else:
        dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    target_sdk_info = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info
    dispatch = _dispatches(dart_sdk_info, target_sdk_info)
    native_assets_yaml, runtime_libs = _code_assets(ctx, dart_sdk_info, target_sdk_info, dispatch, dill)

    if not ctx.attr._modular_kernel[BuildSettingInfo].value:
        # The whole program from source, as `dart_binary` compiles: what the
        # build-wide escape hatch falls back to.
        srcs = collect_transitive_srcs(ctx.attr.deps).to_list() + [ctx.file.main, main] + ctx.files.srcs
        package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
        ctx.actions.write(package_config, kernel_package_config(packages))
        dart_kernel_action(
            ctx = ctx,
            main = main,
            transitive_srcs = depset(srcs),
            package_config = package_config,
            output_dill = dill,
            product = True,
            main_path = kernel_root_path(main.short_path),
            defines = merge_vm_dart_defines(ctx),
            native_assets_yaml = native_assets_yaml,
            roots = kernel_roots(srcs),
        )
    else:
        _link_modules(ctx, sdk, main, packages, own, native_assets_yaml, dill)

    # Thin launcher: run the self-contained dill with asserts enabled. The dill
    # carries all sources/imports, so runfiles need only the VM and (for code
    # assets) the `.so` libraries.
    env = {
        "RULES_DART_DILL": runfiles_path(dill, workspace_name),
    }
    runner_files = []
    if runner:
        # The runner reads the test file for its annotations (`@TestOn`,
        # `@Timeout`, `@Tags`) and names the suite after it.
        env["RULES_DART_TEST_RUNNER"] = runfiles_path(runner, workspace_name)
        env["RULES_DART_TEST_MAIN"] = runfiles_path(ctx.file.main, workspace_name)
        env["RULES_DART_TEST_PATH"] = _test_path(ctx)
        runner_files = [runner, ctx.file.main]
    for key, value in ctx.attr.env.items():
        if key.startswith("RULES_DART_"):
            fail("%s: `env` cannot set %s; rules_dart uses the RULES_DART_ prefix to drive the test" % (ctx.label, key))
        env[key] = ctx.expand_location(value, ctx.attr.data)
    launch = _launch(ctx, dart_sdk_info, target_sdk_info, dispatch, env)

    # A dep's `lib/**` non-Dart files are part of the package at run time under
    # pub, and the dill carries only compiled code — so they come in here, the
    # same way `dart_binary` stages them, and are reached with `rlocation`.
    runfiles = ctx.runfiles(
        files = [dill] + runtime_libs + runner_files + ctx.files.data,
        transitive_files = depset(
            transitive = [collect_transitive_resources(ctx.attr.deps)],
        ),
    )
    runfiles = runfiles.merge(launch.runfiles)
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = launch.executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = launch.env, inherited_environment = ctx.attr.env_inherit),
        # See `dart_binary`: analyzable and fixable without becoming a valid
        # `deps` entry. Built from `ctx.file.main`, not the bootstrap, because
        # the analyze/fix rules stage by `short_path`.
        own.analyzable,
        OutputGroupInfo(_validation = import_check_validation(
            ctx,
            ctx.executable._kernel_tool,
            [ctx.file.main] + ctx.files.srcs,
            own.record,
            ctx.attr.deps,
        )),
    ]

def _abi(sdk):
    """The code-asset ABI of the host an SDK runs on."""
    return "%s_%s" % (sdk.exec_os, sdk.exec_arch)

def _code_assets(ctx, test_sdk, target_sdk, dispatch, dill):
    """The test's code-asset mapping, and the libraries it names.

    The VM loads the libraries built for the host it runs on. When that is the
    target, they are the ones `deps` and `code_assets` already build; when it
    is not (a remote executor, a cross-compiled target), they are the same
    targets built for the test's host, through `test_host_deps`. A test that
    `bazel run` may start on the target carries both, each under its ABI.

    Args:
      ctx: The rule context.
      test_sdk: The `DartSdkInfo` of the `test` group's host.
      target_sdk: The `DartSdkInfo` of the target platform's toolchain.
      dispatch: Whether the executable starts the target's VM on the target.
      dill: The test's kernel, against which the mapping's paths resolve.

    Returns:
      `(native_assets_yaml, libraries)`: the mapping File, or `None` when the
      test has no code assets, and the libraries for its runfiles.
    """
    for_target = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(ctx.attr.deps),
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )
    if not for_target:
        return None, []
    test_abi = _abi(test_sdk)
    if not target_sdk.target_os and test_abi == _abi(target_sdk):
        by_abi = {test_abi: for_target}
    else:
        host_deps = ctx.attr.test_host_deps
        by_abi = {test_abi: resolve_code_assets(
            ctx.label,
            collect_transitive_code_assets([dep for dep in host_deps if DartInfo in dep]),
            [dep[DartCodeAssetInfo] for dep in host_deps if DartCodeAssetInfo in dep],
        )}
        if dispatch:
            by_abi[target_dart_abi(ctx)] = for_target

    # The VM resolves a `relative` path against the dill's real location, the
    # output tree when runfiles are symlinks and the runfiles tree when they
    # are copies, as on a remote executor. A library from another
    # configuration (the test's host's, or any transition's) is where the two
    # trees disagree, so each one is linked in beside the dill, where they
    # agree.
    entries_by_abi = {}
    libraries = []
    for abi, assets in by_abi.items():
        staged = stage_code_assets(
            ctx,
            assets,
            lambda index: "%s.native/%s/%d" % (ctx.label.name, abi, index),
        )
        entries, libs = code_asset_entries(ctx.label, staged, dill.dirname)
        entries_by_abi[abi] = entries
        libraries.extend(libs)
    native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
    ctx.actions.write(
        output = native_assets_yaml,
        content = generate_native_assets_yaml(entries_by_abi),
    )
    return native_assets_yaml, libraries

# How `uname -s`/`uname -m` name each host an SDK is published for.
_UNAME = {
    ("linux", "arm64"): "Linux/aarch64",
    ("linux", "x64"): "Linux/x86_64",
    ("macos", "arm64"): "Darwin/arm64",
    ("macos", "x64"): "Darwin/x86_64",
}

def _dispatches(test_sdk, target_sdk):
    """Whether the executable picks a VM by the machine it finds itself on.

    `bazel test` runs the executable on the `test` group's host, which may be
    a remote executor, but `bazel run` runs it here, on the target. When the
    two differ, the executable is a script that starts whichever launcher and
    VM were built for the machine it is on. A Windows host has no shell to run
    one, and a cross-compiled target no VM to run, so there the test runs only
    on its own host.

    Args:
      test_sdk: The `DartSdkInfo` of the `test` group's host.
      target_sdk: The `DartSdkInfo` of the target platform's toolchain.

    Returns:
      A bool.
    """
    test_host = (test_sdk.exec_os, test_sdk.exec_arch)
    target_host = (target_sdk.exec_os, target_sdk.exec_arch)
    return (test_host != target_host and not target_sdk.target_os and
            test_host in _UNAME and target_host in _UNAME)

def _launch(ctx, test_sdk, target_sdk, dispatch, env):
    """The test's executable, with its runfiles and environment.

    Args:
      ctx: The rule context.
      test_sdk: The `DartSdkInfo` of the `test` group's host.
      target_sdk: The `DartSdkInfo` of the target platform's toolchain.
      dispatch: Whether to start a VM by the machine the script is on (see
        `_dispatches`).
      env: The test's environment, without the VM.

    Returns:
      `struct(executable, runfiles, env)`.
    """
    if not dispatch:
        launcher = test_executable(ctx, ctx.attr._tool)
        return struct(
            executable = launcher.executable,
            runfiles = launcher.runfiles.merge(ctx.runfiles(transitive_files = test_sdk.tool_files)),
            env = env | {"RULES_DART_DART": runfiles_path(test_sdk.dart, ctx.workspace_name)},
        )

    # The two launchers share a workspace path, so each is given its own name
    # for the runfiles to hold both.
    tools = [ctx.attr._tool, ctx.attr._target_tool]
    launchers = []
    for role, tool in zip(["test", "target"], tools):
        launcher = ctx.actions.declare_file("%s.%s_launcher" % (ctx.label.name, role))
        ctx.actions.symlink(output = launcher, target_file = tool[DefaultInfo].files_to_run.executable, is_executable = True)
        launchers.append(launcher)

    def start(launcher, sdk):
        return "export RULES_DART_DART='%s'\nexec \"$RUNFILES_DIR/%s\" \"$@\"" % (
            runfiles_path(sdk.dart, ctx.workspace_name),
            runfiles_path(launcher, ctx.workspace_name),
        )

    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        executable,
        "\n".join([
            "#!/bin/sh",
            "[ -n \"$RUNFILES_DIR\" ] || export RUNFILES_DIR=\"$0.runfiles\"",
            "if [ \"$(uname -s)/$(uname -m)\" = '%s' ]; then" % _UNAME[(test_sdk.exec_os, test_sdk.exec_arch)],
            start(launchers[0], test_sdk),
            "fi",
            start(launchers[1], target_sdk),
            "",
        ]),
        is_executable = True,
    )
    return struct(
        executable = executable,
        runfiles = ctx.runfiles(
            files = launchers,
            transitive_files = depset(transitive = [test_sdk.tool_files, target_sdk.tool_files]),
        ).merge_all([t[DefaultInfo].default_runfiles for t in tools]),
        env = env,
    )

def _link_modules(ctx, sdk, main, packages, own, native_assets_yaml, dill):
    """Compiles the test's own files and entrypoint against its modules, and links them."""
    entry = ctx.actions.declare_file(ctx.label.name + ".entry.dill")
    linked = dart_entry_kernel_action(
        ctx = ctx,
        sdk = sdk,
        kernel_tool = ctx.executable._kernel_tool,
        main = main,
        srcs = [ctx.file.main] + ctx.files.srcs,
        packages = packages,
        modules = collect_modules(ctx.attr.deps),
        output = entry,
        own_package = own.record,
        defines = merge_vm_dart_defines(ctx),
        native_assets_yaml = native_assets_yaml,
    )
    dart_link_kernel_action(ctx, ctx.executable._kernel_tool, entry, linked, dill)

def _test_runner(ctx, packages):
    """The `package:test` runner for this test, or `None` to run it directly.

    The runner is found on the direct dependency that provides `package:test`
    (see `dart_test_runner.bzl`). A test that reaches `package:test` only
    through another library is refused rather than run directly: run directly
    it would silently lose the filter, sharding and timeout behaviour Bazel
    expects, which is a worse failure than a clear one here.

    Args:
      ctx: The rule context.
      packages: The test's `DartPackageInfo` closure.

    Returns:
      The runner `.dill` File, or `None`.
    """
    for dep in ctx.attr.deps:
        if DartTestRunnerInfo in dep:
            return dep[DartTestRunnerInfo].runner
    for pkg in packages:
        if pkg.package_name == "test":
            fail(("%s: depends on `package:test` without listing it in " +
                  "`deps`. Add the `package:test` target (e.g. " +
                  "`@<hub>//:test`) to `deps`: `dart_test` runs tests through " +
                  "the runner that target carries.") % ctx.label)
    return None

def _test_path(ctx):
    """The test's path as the runner names it.

    That is its `short_path`, with a file from another repository placed under
    `external/` rather than above the root.

    Args:
      ctx: The rule context.

    Returns:
      The forward-slashed relative path.
    """
    path = ctx.file.main.short_path
    return "external/" + path[3:] if path.startswith("../") else path

_BOOTSTRAP = """\
// Generated by rules_dart: runs `{test}` under the `package:test` runner.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/bootstrap/vm.dart';

import '{import_path}' as test;

void main(List<String> _, SendPort sendPort) {{
  internalBootstrapVmTest(() {{
    final Function main = test.main;
    // The runner calls `main` with no arguments. A test that reads its
    // `args` gets the ones Bazel would have passed it, from the launcher.
    if (main is void Function(List<String>)) {{
      final encoded = Platform.environment['RULES_DART_TEST_ARGS'] ?? '[]';
      final args = (jsonDecode(encoded) as List).cast<String>();
      return () => main(args);
    }}
    return main;
  }}, sendPort);
}}
"""

_FORWARDER = """\
// Generated by rules_dart: runs `{test}`, which is compiled with its sources.
import '{import_path}' as test;

Object? main(List<String> args) {{
  final Function main = test.main;
  return main is Function(Never) ? Function.apply(main, [args]) : Function.apply(main, const []);
}}
"""

def _write_forwarder(ctx):
    """Writes the entrypoint that calls a test run without `package:test`.

    The test's own files are compiled as a module, with their line numbers;
    this is the one file compiled against the modules, which records `main`.

    Args:
      ctx: The rule context.

    Returns:
      The forwarder File.
    """
    return _write_entrypoint(ctx, ctx.label.name + ".main.dart", _FORWARDER)

def _write_bootstrap(ctx):
    """Writes the entrypoint that runs the test under the `package:test` runner.

    The test file is imported by a path relative to the bootstrap, so its own
    relative imports and `part`s resolve exactly as when it is compiled
    directly.

    Args:
      ctx: The rule context.

    Returns:
      The bootstrap File.
    """
    return _write_entrypoint(ctx, ctx.label.name + ".vm_test.dart", _BOOTSTRAP)

def _write_entrypoint(ctx, name, template):
    """Writes a generated entrypoint importing the test file.

    Both are read through the kernel roots, where a generated file and a
    source file share one tree, so the import is the relative path between
    their root-relative locations.

    Args:
      ctx: The rule context.
      name: The file to declare.
      template: The content, with `{test}` and `{import_path}`.

    Returns:
      The File.
    """
    out = ctx.actions.declare_file(name)
    from_dir = kernel_root_path(out.short_path).rpartition("/")[0]
    to = kernel_root_path(ctx.file.main.short_path)
    to_dir, _, to_name = to.rpartition("/")
    rel = relative_path(from_dir, to_dir)
    ctx.actions.write(
        output = out,
        content = template.format(
            test = ctx.file.main.short_path,
            import_path = to_name if rel == "." else rel + "/" + to_name,
        ),
    )
    return out

def _dart_test_initializer(name, deps = None, code_assets = None, test_host_deps = None, **_attrs):
    if test_host_deps != None:
        fail("%s: `test_host_deps` is set by `dart_test` from `deps` and `code_assets`" % name)
    if deps == None and code_assets == None:
        return {}
    return {"test_host_deps": (deps if deps != None else []) + (code_assets if code_assets != None else [])}

dart_test = rule(
    implementation = _dart_test_impl,
    initializer = _dart_test_initializer,
    attrs = dict({
        "main": attr.label(
            doc = "The Dart test file to run. Must contain a top-level `main()` function.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart source files that are part of this test's package but not reachable via `deps`.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "`dart_library` targets this test depends on.",
            providers = [DartInfo],
            aspects = [vm_module_aspect, dart_import_check_aspect],
            cfg = module_defines_transition,
        ),
        "data": attr.label_list(
            doc = "Additional files needed at runtime. These are added to runfiles so they can be resolved via `Runfiles.rlocation()`.",
            allow_files = True,
        ),
        "defines": attr.string_list(
            doc = """Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` \
flag on the build-time compile, so `String.fromEnvironment` resolves to it. Set these here rather \
than at run time: the test's `main` is compiled to a kernel during the build, and environment \
declarations are resolved by the front end at that point — the VM cannot supply them later.""",
        ),
        "code_assets": attr.label_list(
            doc = """Native code assets (e.g. `//dart/ext/sqlite3:code_asset`) the test's \
`@Native` FFI bindings resolve against. When set, the test's `main` is compiled to a kernel \
with the code-asset mapping embedded (`gen_kernel --native-assets`), and the libraries ship in \
runfiles so the Dart VM resolves them — no `dart:ffi` ceremony in the test source. Each entry \
must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule). An entry replaces the asset with the same id that `deps` supply, so a test can load a differently built library under that id.""",
            providers = [DartCodeAssetInfo],
        ),
        "test_host_deps": attr.label_list(
            doc = """Set by the rule, never by hand: `deps` and `code_assets` again, built \
for the host the test runs on. When that host is not the target (a remote executor, say), the \
test loads the code assets built here.""",
            providers = [[DartInfo], [DartCodeAssetInfo]],
            cfg = config.exec("test"),
        ),
        "env": attr.string_dict(
            doc = """Environment variables set when the test runs. Values expand \
`$(rlocationpath ...)` and the other location functions for labels in `data`, so a test can be \
told where a runfile is (resolve it with `Runfiles.rlocation()`).""",
        ),
        "env_inherit": attr.string_list(
            doc = "Names of environment variables passed through from the environment `bazel test` runs in.",
        ),
        "_modular_kernel": attr.label(default = Label("//dart:modular_kernel")),
        "_tool": attr.label(
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = config.exec("test"),
        ),
        # The same launcher for the target, which `bazel run` runs it on.
        "_target_tool": attr.label(
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = "target",
        ),
    }, **dict(DART_ABI_CONSTRAINT_ATTRS, **dict(EXTRA_DART_DEFINES_ATTR, **dict(MODULE_EXECUTABLE_ATTRS, **EXECUTABLE_PACKAGE_ATTRS)))),
    test = True,
    # A kernel runs on any host the SDK runs on. Bazel runs a test in the
    # `test` group, which by default matches the target platform; this one
    # asks only for an SDK. The compiles before it are `portable`, and the
    # target's own SDK is what `bazel run` starts.
    toolchains = ["//dart:toolchain_type"],
    exec_groups = PORTABLE_EXEC_GROUPS | {
        "test": exec_group(toolchains = [EXEC_TOOLS_TOOLCHAIN]),
    },
    doc = (
        "Compiles a Dart test to a kernel at build time and runs it with " +
        "asserts enabled. A test with `package:test` in `deps` runs under " +
        "that package's runner, so `--test_filter`, `shard_count` and " +
        "per-case results work and Bazel's `timeout` is the only time limit. " +
        "It runs on any host with a Dart SDK, whatever the target platform, " +
        "so a remote executor can run it, with its native `code_assets` " +
        "built for that host. One that needs the target's own host (a binary " +
        "from `data`, a tool such as `xcrun`) says so with " +
        "`exec_group_compatible_with = {\"test\": [...]}`. " +
        "`target_compatible_with` does not move the run."
    ),
)
