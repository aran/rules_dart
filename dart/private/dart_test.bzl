"""Implementation of the dart_test rule."""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "create_test_executable", "runfiles_path")

def _generate_packages_manifest(ctx, deps):
    """Generate a packages manifest for runtime package_config.json construction.

    Each line has: <name>\t<runfiles_root>\t<runfiles_representative_file>
    The test runner uses rlocation on the representative file to derive
    the absolute package root path, making this work on all platforms
    (including Windows manifest-only mode).
    """
    workspace_name = ctx.workspace_name

    packages = []
    seen = {}
    for dep in deps:
        info = dep[DartInfo]
        for pkg in info.transitive_packages.to_list():
            if pkg.package_name not in seen:
                seen[pkg.package_name] = True
                packages.append(pkg)

    # Collect all transitive source files to find a representative per package
    all_srcs = []
    for dep in deps:
        all_srcs.extend(dep[DartInfo].transitive_srcs.to_list())

    # Build a map from lib_root to (runfiles_root, representative_file).
    # Both src.path and lib_root are exec-root-relative, so we match in
    # that coordinate system, then derive the runfiles root from the
    # matched source's short_path. This handles source-tree, external,
    # and generated (bazel-out/) packages uniformly.
    root_to_entry = {}
    for src in all_srcs:
        src_rpath = runfiles_path(src, workspace_name)
        for pkg in packages:
            lib_root = pkg.lib_root
            if lib_root in root_to_entry:
                continue
            if src.path.startswith(lib_root + "/"):
                suffix = src.path[len(lib_root):]
                rf_root = src_rpath[:len(src_rpath) - len(suffix)]
                root_to_entry[lib_root] = (rf_root, src_rpath)

    manifest = ctx.actions.declare_file(ctx.label.name + ".packages")
    lines = []
    for pkg in packages:
        entry = root_to_entry.get(pkg.lib_root)
        if entry:
            rf_root, rep_file = entry
            lines.append("{name}\t{root}\t{file}".format(
                name = pkg.package_name,
                root = rf_root,
                file = rep_file,
            ))

    ctx.actions.write(output = manifest, content = "\n".join(lines) + "\n")
    return manifest

def _dart_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info

    # Collect all transitive sources from deps
    all_srcs = list(ctx.files.srcs)
    for dep in ctx.attr.deps:
        all_srcs.extend(dep[DartInfo].transitive_srcs.to_list())

    # Generate packages manifest for runtime package_config.json construction
    packages_manifest = _generate_packages_manifest(ctx, ctx.attr.deps)

    # Resolve runfiles-relative paths for env vars
    workspace_name = ctx.workspace_name
    dart_path = runfiles_path(dart_sdk_info.dart, workspace_name)
    manifest_path = runfiles_path(packages_manifest, workspace_name)
    main_path = runfiles_path(ctx.file.main, workspace_name)

    # Create test executable from pre-compiled runner
    executable, env_info, tool_runfiles = create_test_executable(
        ctx,
        ctx.attr._tool,
        env = {
            "RULES_DART_DART": dart_path,
            "RULES_DART_PKG_MANIFEST": manifest_path,
            "RULES_DART_MAIN": main_path,
        },
    )

    # Build runfiles with all needed files
    runfiles = ctx.runfiles(
        files = [ctx.file.main, packages_manifest] + all_srcs + ctx.files.data + dart_sdk_info.tool_files,
    )
    runfiles = runfiles.merge(tool_runfiles)
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        env_info,
    ]

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
        "_tool": attr.label(
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = "exec",
        ),
    }, **WINDOWS_CONSTRAINT_ATTR),
    test = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs a Dart test file using the Dart VM.",
)
