"""Implementation of the dart_test rule.

The test is compiled to kernel **at build time** and the launcher merely runs
it, so no sources and no `package_config` are needed at run time. Its
dependencies are compiled once each, into the kernel modules
`dart_module_aspect` builds; the test compiles only its own files against them
and links the program (see `dart_module.bzl`): a kernel list naming the
kernels, which the launcher rewrites with where it finds each in runfiles, tree
or manifest; or, with `--@rules_dart//dart:kernel_list=false`, one joined
kernel.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartKernelSdkInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "KERNEL_LIST_ATTR", "RUNNER_SNAPSHOT_ATTR", "TRACK_CREATION_LOCATIONS_ATTR", "kernel_list", "runner_snapshot", "track_creation_locations")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_transitive_code_assets",
    "collect_transitive_resources",
    "generate_native_assets_yaml",
    "kernel_root_path",
    "launcher_executable",
    "relative_path",
    "resolve_code_assets",
    "runfiles_path",
    "stage_code_assets",
    "target_dart_abi",
)
load("//dart/private:dart_coverage.bzl", "COVERAGE_ATTRS", "test_coverage")
load("//dart/private:dart_import_check.bzl", "dart_import_check_aspect", "import_check_validation")
load(
    "//dart/private:dart_module.bzl",
    "MODULE_EXECUTABLE_ATTRS",
    "PROGRAM_KERNEL_SDK_ATTR",
    "collect_modules",
    "dart_entry_kernel_action",
    "dart_link_kernel_action",
    "executable_defines",
    "executable_defines_config",
    "vm_module_aspect",
    "whole_program_kernel",
)
load("//dart/private:dart_test_runner.bzl", "DartTestRunnerInfo")
load("//dart/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//dart/private:executable_package.bzl", "EXECUTABLE_PACKAGE_ATTRS", "executable_package")

# The test's `defines` are the environment of its dependencies' modules too.
_ENVIRONMENT = executable_defines_config()

def _dart_test_impl(ctx):
    # The VM that runs the test: the target's, as everything the test runs is.
    dart_sdk_info = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info
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
    native_assets_yaml, runtime_libs = _code_assets(ctx, own.record, dill)
    modular = ctx.attr._modular_kernel[BuildSettingInfo].value

    # What the program needs beside it: the kernels a kernel list names.
    program_files = depset()
    if not modular:
        # The whole program from source, as `dart_binary` compiles: what the
        # build-wide escape hatch falls back to.
        whole_program_kernel(
            ctx,
            main = main,
            packages = packages,
            output_dill = dill,
            defines = executable_defines(ctx),
            native_assets_yaml = native_assets_yaml,
            track_creation_locations = track_creation_locations(ctx),
        )
    else:
        program_files = _link_modules(ctx, sdk, main, packages, own, native_assets_yaml, dill)

    # Thin launcher: run the compiled program with asserts enabled. It carries
    # all sources/imports, so runfiles need only the VM, the kernels and (for
    # code assets) the `.so` libraries. What to run is in a file beside the
    # launcher, not in its environment, so that the test runs its own program
    # however it is started, as another target's `data` included.
    config = {
        "dart": runfiles_path(dart_sdk_info.dart, workspace_name),
        "dill": runfiles_path(dill, workspace_name),
    }
    if modular and kernel_list(ctx):
        # The launcher writes the list again naming each kernel where it found
        # it, and puts each library beside that list as they are beside `dill`
        # (see `_code_assets`).
        config["kernel_list"] = True
        config["code_asset_libraries"] = [runfiles_path(lib, workspace_name) for lib in runtime_libs]
    runner_files = []
    config.update(_tag_selection(ctx, runner))
    if runner:
        # The runner reads the test file for its annotations (`@TestOn`,
        # `@Timeout`, `@Tags`) and names the suite after it.
        config["runner"] = runfiles_path(runner.runner, workspace_name)
        config["test_main"] = runfiles_path(ctx.file.main, workspace_name)
        config["test_path"] = _test_path(ctx)
        runner_files = [runner.runner, ctx.file.main]
        if runner_snapshot(ctx):
            # What names the cached snapshot: the runner, by its digest, and
            # the VM that runs it. A snapshot of another runner, or made by
            # another VM, is never started from.
            config["runner_snapshot"] = {
                "digest": runfiles_path(runner.digest, workspace_name),
                "vm": "%s-%s-%s" % (dart_sdk_info.version, dart_sdk_info.exec_os, dart_sdk_info.exec_arch),
            }
            runner_files.append(runner.digest)
    coverage = test_coverage(ctx, packages, [ctx.file.main] + ctx.files.srcs, ctx.attr.deps)
    if coverage:
        config["coverage"] = {
            "collector": runfiles_path(ctx.executable._coverage_collector, ctx.workspace_name),
            "converter": coverage.converter,
            "sources": coverage.sources,
        }
    config_file = ctx.actions.declare_file(ctx.label.name + ".launcher.json")
    ctx.actions.write(output = config_file, content = json.encode(config))
    env = {}
    for key, value in ctx.attr.env.items():
        # The launcher keeps its own `RULES_DART_` variables from the test.
        if key.startswith("RULES_DART_"):
            fail("%s: `env` cannot set %s; rules_dart uses the RULES_DART_ prefix to drive the test" % (ctx.label, key))
        env[key] = ctx.expand_location(value, ctx.attr.data)
    launcher = launcher_executable(ctx, ctx.attr._tool)

    # A dep's `lib/**` non-Dart files are part of the package at run time under
    # pub, and the dill carries only compiled code — so they come in here, the
    # same way `dart_binary` stages them, and are reached with `rlocation`.
    runfiles = ctx.runfiles(
        files = [dill, config_file] + runtime_libs + runner_files + ctx.files.data,
        transitive_files = depset(
            # The VM that runs the kernel, and no more of the SDK: a test that
            # runs SDK commands itself takes `@rules_dart//dart` in `data`.
            transitive = [dart_sdk_info.files.run, program_files, collect_transitive_resources(ctx.attr.deps)],
        ),
    )
    runfiles = runfiles.merge(launcher.runfiles)
    if coverage:
        runfiles = runfiles.merge(coverage.runfiles).merge(ctx.attr._coverage_collector[DefaultInfo].default_runfiles)
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = launcher.executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = env, inherited_environment = ctx.attr.env_inherit),
        # See `dart_binary`: analyzable and fixable without becoming a valid
        # `deps` entry. Built from `ctx.file.main`, not the bootstrap, because
        # the analyze/fix rules stage by `short_path`.
        own.analyzable,
        # What `bazel coverage` reports on: the test's own files and its
        # libraries', as `--instrumentation_filter` selects them.
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["main", "srcs"],
            dependency_attributes = ["deps"],
            extensions = ["dart"],
        ),
        OutputGroupInfo(_validation = import_check_validation(
            ctx,
            ctx.executable._kernel_tool,
            [ctx.file.main] + ctx.files.srcs,
            own.record,
            ctx.attr.deps,
        )),
    ]

def _code_assets(ctx, package, dill):
    """The test's code-asset mapping, and the libraries it names.

    Args:
      ctx: The rule context.
      package: The test's own `DartPackageInfo`, or `None`.
      dill: The test's kernel, against which the mapping's paths resolve.

    Returns:
      `(native_assets_yaml, libraries)`: the mapping File, or `None` when the
      test has no code assets, and the libraries for its runfiles.
    """
    assets = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(package, ctx.attr.deps),
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )
    if not assets:
        return None, []
    abi = target_dart_abi(ctx)

    # The VM resolves a `relative` path against the dill's real location, the
    # output tree when runfiles are symlinks and the runfiles tree when they
    # are copies, as on a remote executor. A library from another
    # configuration (any transition's) is where the two trees disagree, so
    # each one is linked in beside the dill, where they agree.
    staged = stage_code_assets(
        ctx,
        assets,
        lambda index: "%s.native/%s/%d" % (ctx.label.name, abi, index),
    )
    entries, libraries = code_asset_entries(ctx.label, staged, dill.dirname)
    native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
    ctx.actions.write(
        output = native_assets_yaml,
        content = generate_native_assets_yaml(abi, entries),
    )
    return native_assets_yaml, libraries

def _link_modules(ctx, sdk, main, packages, own, native_assets_yaml, dill):
    """Compiles the test's own files and entrypoint against its modules, and links them.

    Returns:
      A depset of the files the program names, for its runfiles.
    """
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
        native_assets_yaml = native_assets_yaml,
        track_creation_locations = track_creation_locations(ctx),
    )
    return dart_link_kernel_action(
        ctx,
        ctx.executable._kernel_tool,
        entry,
        linked,
        dill,
        kernel_list = kernel_list(ctx),
    )

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
      The runner's `DartTestRunnerInfo`, or `None`.
    """
    for dep in ctx.attr.deps:
        if DartTestRunnerInfo in dep:
            return dep[DartTestRunnerInfo]
    for pkg in packages:
        if pkg.package_name == "test":
            fail(("%s: depends on `package:test` without listing it in " +
                  "`deps`. Add the `package:test` target (e.g. " +
                  "`@<hub>//:test`) to `deps`: `dart_test` runs tests through " +
                  "the runner that target carries.") % ctx.label)
    return None

def _tag_selection(ctx, runner):
    """The launcher config's `include_tags`/`exclude_tags`, when set.

    Args:
      ctx: The rule context.
      runner: The test's `DartTestRunnerInfo`, or `None`.

    Returns:
      A dict of the attributes that are set.
    """
    selection = {}
    for attr in ("include_tags", "exclude_tags"):
        selectors = getattr(ctx.attr, attr)
        if not selectors:
            continue
        if not runner:
            fail("%s: `%s` needs a test written with `package:test`; this one has a plain `main()` and no cases to select" % (ctx.label, attr))
        for selector in selectors:
            # The runner splits a `--tags` value at commas, which a boolean
            # selector never contains.
            if not selector.strip() or "," in selector:
                fail("%s: `%s` entry %r is not one tag selector; give each selector an entry of its own" % (ctx.label, attr, selector))
        selection[attr] = selectors
    return selection

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
            aspects = [vm_module_aspect, dart_import_check_aspect],
            cfg = _ENVIRONMENT.cfg,
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
with the code-asset mapping embedded (`frontend_server --native-assets`), and the libraries ship in \
runfiles so the Dart VM resolves them — no `dart:ffi` ceremony in the test source. Each entry \
must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule). An entry replaces the asset with the same id that `deps` supply, so a test can load a differently built library under that id.""",
            providers = [DartCodeAssetInfo],
        ),
        "env": attr.string_dict(
            doc = """Environment variables set when the test runs. Values expand \
`$(rlocationpath ...)` and the other location functions for labels in `data`, so a test can be \
told where a runfile is (resolve it with `Runfiles.rlocation()`).""",
        ),
        "env_inherit": attr.string_list(
            doc = "Names of environment variables passed through from the environment `bazel test` runs in.",
        ),
        # Which cases of the suite run, as the `include_tags` and
        # `exclude_tags` keys of `dart_test.yaml`, which `dart_test` does not
        # read. They choose cases inside this target, unlike Bazel's `tags`
        # and `--test_tag_filters`, which choose targets.
        "include_tags": attr.string_list(
            doc = """`package:test` tag selectors a case must match to run, as `dart test \
--tags` takes them and as `dart_test.yaml`'s `include_tags` does: each entry is one boolean \
selector (`unit`, `a && !b`), and a case must match every entry. Tags come from `@Tags` on the \
test library and `tags:` on `group` and `test`; they are not Bazel's `tags`. A target none of \
whose cases match fails. `--test_env=DART_TEST_TAGS=<selector>` narrows further for one run. \
Needs `package:test` in `deps`.""",
        ),
        "exclude_tags": attr.string_list(
            doc = """`package:test` tag selectors that drop a case, as `dart test \
--exclude-tags` takes them and as `dart_test.yaml`'s `exclude_tags` does: a case matching any \
entry does not run. A target none of whose cases remain fails. \
`--test_env=DART_TEST_EXCLUDE_TAGS=<selector>` drops more for one run. Needs `package:test` in \
`deps`.""",
        ),
        "_modular_kernel": attr.label(default = Label("//dart:modular_kernel")),
        # Run by the launcher under `bazel coverage`, and in runfiles only then.
        "_coverage_collector": attr.label(
            default = "//dart/private/tools:coverage_collector",
            executable = True,
            cfg = "target",
        ),
        "_tool": attr.label(
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = "target",
        ),
    }, **dict(COVERAGE_ATTRS, **dict(DART_ABI_CONSTRAINT_ATTRS, **dict(KERNEL_LIST_ATTR, **dict(RUNNER_SNAPSHOT_ATTR, **dict(EXTRA_DART_DEFINES_ATTR, **dict(TRACK_CREATION_LOCATIONS_ATTR, **dict(MODULE_EXECUTABLE_ATTRS, **dict(PROGRAM_KERNEL_SDK_ATTR, **dict(_ENVIRONMENT.attrs, **EXECUTABLE_PACKAGE_ATTRS)))))))))),
    test = True,
    # The compiles are `portable`. The run is Bazel's own `test` group, which
    # puts it on a host matching the target: everything it runs, the VM and
    # native `code_assets` included, is built for the target.
    toolchains = ["//dart:toolchain_type"],
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = (
        "Compiles a Dart test to a kernel at build time and runs it with " +
        "asserts enabled. A test with `package:test` in `deps` runs under " +
        "that package's runner, so `--test_filter`, `shard_count` and " +
        "per-case results work and Bazel's `timeout` is the only time limit. " +
        "Like any Bazel test it is built for the target platform and runs on " +
        "a host matching it; to run it elsewhere, build it for that platform " +
        "(`--platforms`, or a platform transition such as " +
        "`platform_transition_test`)."
    ),
)
