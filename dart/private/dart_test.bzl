"""Implementation of the dart_test rule."""

load("//dart:providers.bzl", "DartInfo")

def _runfiles_path(f, workspace_name):
    """Convert a File to its path in the runfiles tree."""
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return workspace_name + "/" + f.short_path

def _generate_runtime_package_config(ctx, deps):
    """Generate package_config.json with rootUri values correct for the runfiles tree.

    At runtime (test execution), files are in the runfiles tree where both
    the config file and sources share the same workspace-relative layout.
    We compute rootUri relative to the config file's short_path dirname.
    """
    packages = []
    seen = {}
    for dep in deps:
        info = dep[DartInfo]
        for pkg in info.transitive_packages.to_list():
            if pkg.package_name not in seen:
                seen[pkg.package_name] = True
                packages.append(pkg)

    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")

    # Compute depth from the config file's short_path directory.
    if "/" in package_config.short_path:
        dirname = package_config.short_path.rsplit("/", 1)[0]
        depth = len(dirname.split("/"))
    else:
        depth = 0

    prefix = "/".join([".."] * depth) if depth > 0 else ""

    if not packages:
        content = '{"configVersion": 2, "packages": []}\n'
    else:
        entries = []
        for pkg in packages:
            lib_root = pkg.lib_root

            # In the runfiles tree, external repos are siblings of _main/
            # (e.g. $RUNFILES/repo_name/pkg/), not under _main/external/.
            # Convert workspace_root-based paths to runfiles-relative paths.
            if lib_root.startswith("external/"):
                lib_root = "../" + lib_root[len("external/"):]

            root_uri = prefix + "/" + lib_root if prefix else lib_root
            entries.append(
                '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"}}'.format(
                    name = pkg.package_name,
                    root_uri = root_uri,
                ),
            )
        content = '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
            packages = ",\n".join(entries),
        )

    ctx.actions.write(output = package_config, content = content)
    return package_config

def _dart_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # Collect all transitive sources from deps
    all_srcs = list(ctx.files.srcs)
    for dep in ctx.attr.deps:
        all_srcs.extend(dep[DartInfo].transitive_srcs.to_list())

    # Generate package_config.json for runtime
    package_config = _generate_runtime_package_config(ctx, ctx.attr.deps)

    # Generate test runner shell script
    workspace_name = ctx.workspace_name
    dart_path = _runfiles_path(dart_sdk_info.dart, workspace_name)
    pkg_config_path = _runfiles_path(package_config, workspace_name)
    main_path = _runfiles_path(ctx.file.main, workspace_name)

    test_runner = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        output = test_runner,
        content = """#!/usr/bin/env bash
set -euo pipefail
RUNFILES="${{RUNFILES_DIR:-$0.runfiles}}"
exec "$RUNFILES/{dart}" --packages="$RUNFILES/{pkg_config}" "$RUNFILES/{main}"
""".format(
            dart = dart_path,
            pkg_config = pkg_config_path,
            main = main_path,
        ),
        is_executable = True,
    )

    # Build runfiles with all needed files
    runfiles = ctx.runfiles(
        files = [ctx.file.main, package_config] + all_srcs + dart_sdk_info.tool_files,
    )
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = test_runner,
            runfiles = runfiles,
        ),
    ]

dart_test = rule(
    implementation = _dart_test_impl,
    attrs = {
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
    },
    test = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs a Dart test file using the Dart VM.",
)
