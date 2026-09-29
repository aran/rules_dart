"""Implementation of the dart_test rule.

Unified with `dart_binary`: the test's `main` is compiled to a self-contained
kernel (`.dill`) **at build time**, so package resolution and `part`/`import`
co-location happen in the execroot — exactly where `dart_binary` already proves
they work — and the test launcher merely runs the dill. No sources, no
`package_config`, and no co-location are needed at runtime, so manifest-mode
runfiles (Windows) are a non-issue.
"""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_dart_defines")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "WINDOWS_CONSTRAINT_ATTR",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_packages",
    "collect_transitive_code_assets",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "create_test_executable",
    "gen_kernel_native_assets_action",
    "generate_native_assets_yaml",
    "generate_package_config",
    "resolve_code_assets",
    "runfiles_path",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "dart_compile_action")
load("//dart/private:dart_info.bzl", "dart_analyzable_info")
load("//dart/private:dart_test_runner.bzl", "DartTestRunnerInfo")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "colocate_entrypoint", "colocate_packages")

def _dart_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    workspace_name = ctx.workspace_name

    # Co-locate each dep package's source+generated (and split-across-targets)
    # files into one real directory, and the test's own `main` with any generated
    # sibling sources (e.g. a `.mocks.dart`), so the build-time compile resolves
    # everything.
    packages = collect_packages(ctx.attr.deps)
    runner = _test_runner(ctx, packages)

    hook_err = check_unreplaced_hooks(ctx.label, packages)
    if hook_err != None:
        fail(hook_err)

    # The one flatten per rule: colocation inspects per-file paths.
    packages, dep_srcs = colocate_packages(ctx, packages, collect_transitive_srcs(ctx.attr.deps).to_list())
    main_input, main_arg, own_inputs = colocate_entrypoint(ctx, ctx.file.main, ctx.files.srcs)
    compile_srcs = dep_srcs + own_inputs
    if runner:
        # Under the runner the compiled entrypoint is a bootstrap that hands
        # `main` to `package:test`; the test file itself becomes an input.
        compile_srcs = compile_srcs + [main_input]
        main_input = _write_bootstrap(ctx, main_arg)
        main_arg = main_input.path

    # Root resolution must see the rule's own inputs too: a package whose
    # metadata comes from a srcs-less façade library resolves only via the
    # files this rule supplies itself.
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = generate_package_config(packages, compile_srcs, package_config),
    )

    if runner:
        # Declared where the runner's `--precompiled` layout expects it, so it
        # is loaded in place: code-asset paths are relative to the dill, and a
        # copy elsewhere would leave them pointing at nothing.
        dill = ctx.actions.declare_file(
            "%s.precompiled/%s.vm_test.vm.app.dill" % (ctx.label.name, _test_path(ctx)),
        )
    else:
        dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    defines = merge_dart_defines(ctx)
    runtime_libs = []

    # Transitively propagated assets plus any named outright — see the same
    # comment in `dart_binary`.
    resolved_assets = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(ctx.attr.deps),
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )

    if resolved_assets:
        # Embed the code-asset mapping in the kernel (`gen_kernel --native-assets`),
        # with `relative` paths resolved against the dill at runtime — the same
        # build-time path `dart_binary` uses. The `.so` libraries ship in runfiles.
        abi = target_dart_abi(ctx)
        entries, runtime_libs = code_asset_entries(
            ctx.label,
            resolved_assets,
            dill.dirname,
        )
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(abi, entries),
        )
        gen_kernel_native_assets_action(
            ctx = ctx,
            dart_sdk_info = dart_sdk_info,
            main = main_input,
            transitive_srcs = depset(compile_srcs),
            package_config = package_config,
            native_assets_yaml = native_assets_yaml,
            output_dill = dill,
            main_path = main_arg,
            defines = defines,
        )
    else:
        dart_compile_action(
            ctx = ctx,
            dart_bin = dart_sdk_info.dart,
            sdk_files = dart_sdk_info.tool_files,
            main = main_input,
            srcs = compile_srcs,
            package_config = package_config,
            output = dill,
            compile_mode = "kernel",
            main_path = main_arg,
            defines = defines,
        )

    # Thin launcher: run the self-contained dill with asserts enabled. The dill
    # carries all sources/imports, so runfiles need only the VM and (for code
    # assets) the `.so` libraries.
    env = {
        "RULES_DART_DART": runfiles_path(dart_sdk_info.dart, workspace_name),
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
    executable, env_info, tool_runfiles = create_test_executable(
        ctx,
        ctx.attr._tool,
        env = env,
    )

    # A dep's `lib/**` non-Dart files are part of the package at run time under
    # pub, and the dill carries only compiled code — so they come in here, the
    # same way `dart_binary` stages them, and are reached with `rlocation`.
    runfiles = ctx.runfiles(
        files = [dill] + runtime_libs + runner_files + ctx.files.data,
        transitive_files = depset(
            transitive = [
                dart_sdk_info.tool_files,
                collect_transitive_resources(ctx.attr.deps),
            ],
        ),
    )
    runfiles = runfiles.merge(tool_runfiles)
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        env_info,
        # See `dart_binary`: analyzable and fixable without becoming a valid
        # `deps` entry. `ctx.file.main` is the pre-colocation file, because the
        # analyze/fix rules stage by `short_path`.
        dart_analyzable_info(
            deps = ctx.attr.deps,
            srcs = [ctx.file.main] + ctx.files.srcs,
        ),
    ]

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

def _write_bootstrap(ctx, main_path):
    """Writes the entrypoint compiled in place of the test's own `main`.

    The test file is imported by a path relative to the bootstrap, which is
    what keeps its own relative imports and `part`s resolving exactly as they
    do when it is compiled directly.

    Args:
      ctx: The rule context.
      main_path: Exec-root-relative path of the test's (possibly colocated)
        main file.

    Returns:
      The bootstrap File.
    """
    bootstrap = ctx.actions.declare_file(ctx.label.name + ".vm_test.dart")
    depth = len(bootstrap.dirname.split("/"))
    ctx.actions.write(
        output = bootstrap,
        content = _BOOTSTRAP.format(
            test = ctx.file.main.short_path,
            import_path = "../" * depth + main_path,
        ),
    )
    return bootstrap

dart_test = rule(
    implementation = _dart_test_impl,
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
must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule).""",
            providers = [DartCodeAssetInfo],
        ),
        "_tool": attr.label(
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = "exec",
        ),
    }, **dict(WINDOWS_CONSTRAINT_ATTR, **dict(DART_ABI_CONSTRAINT_ATTRS, **EXTRA_DART_DEFINES_ATTR))),
    test = True,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = (
        "Compiles a Dart test to a kernel at build time and runs it with " +
        "asserts enabled. A test with `package:test` in `deps` runs under " +
        "that package's runner, so `--test_filter`, `shard_count` and " +
        "per-case results work and Bazel's `timeout` is the only time limit."
    ),
)
