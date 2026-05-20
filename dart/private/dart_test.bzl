"""Implementation of the dart_test rule."""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "WINDOWS_CONSTRAINT_ATTR",
    "create_test_executable",
    "find_sdk_kernel_tools",
    "runfiles_path",
    "target_dart_abi",
)

def format_packages_manifest_lines(packages, root_to_entry):
    """Build the per-package manifest lines.

    Each line has four tab-separated columns:
    `<name>\t<runfiles_root>\t<runfiles_representative_file>\t<language_version>`.
    The fourth column is empty when the package has no declared language
    version; the test runner only emits `languageVersion` in the resulting
    `package_config.json` entry when the column is non-empty (mirroring
    `common.bzl::generate_package_config`'s "non-empty wins" predicate so
    build-time and runtime JSON match).

    Packages whose `lib_root` is missing from `root_to_entry` are skipped
    silently — there are no source files in the runfiles tree to represent
    them, so the analyzer/runtime cannot resolve `package:` URIs into them
    anyway.

    Args:
      packages: List of `DartPackageInfo` providers (or struct fakes for
        unit tests).
      root_to_entry: Dict mapping `lib_root` to
        `(runfiles_root, representative_file)`.

    Returns:
      List of formatted manifest lines (no trailing newline).
    """
    lines = []
    for pkg in packages:
        entry = root_to_entry.get(pkg.lib_root)
        if entry == None:
            continue
        rf_root, rep_file = entry
        lines.append("{name}\t{root}\t{file}\t{lv}".format(
            name = pkg.package_name,
            root = rf_root,
            file = rep_file,
            lv = pkg.language_version,
        ))
    return lines

def _generate_packages_manifest(ctx, deps):
    """Generate a packages manifest for runtime package_config.json construction.

    See `format_packages_manifest_lines` for the per-line schema.
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
    # Both src.short_path and lib_root are in the same short_path coordinate
    # system, so matching is straightforward. This handles source-tree,
    # external, and generated (bazel-out/) packages uniformly.
    root_to_entry = {}
    for src in all_srcs:
        src_rpath = runfiles_path(src, workspace_name)
        for pkg in packages:
            lib_root = pkg.lib_root
            if lib_root in root_to_entry:
                continue
            if src.short_path.startswith(lib_root + "/") or \
               (src.is_directory and src.short_path == lib_root):
                suffix = src.short_path[len(lib_root):]
                rf_root = src_rpath[:len(src_rpath) - len(suffix)]
                root_to_entry[lib_root] = (rf_root, src_rpath)

    manifest = ctx.actions.declare_file(ctx.label.name + ".packages")
    lines = format_packages_manifest_lines(packages, root_to_entry)

    ctx.actions.write(output = manifest, content = "\n".join(lines) + "\n")
    return manifest

def _dart_test_code_assets_impl(ctx, dart_sdk_info, all_srcs, packages_manifest):
    """code_assets path: compile main->kernel with native assets, run the dill.

    The kernel compile happens at TEST time inside the runner (not as a build
    action), because a codegen package's source and generated files only
    co-locate in the runfiles tree — the same reason the default path resolves
    packages at runtime. The runner reuses the runtime package_config built
    from `packages_manifest`, then writes a native_assets.yaml that points each
    asset at the rlocation-resolved (absolute) `.so`, runs
    `gen_kernel --native-assets`, and runs the resulting dill.
    """
    workspace_name = ctx.workspace_name
    tools = find_sdk_kernel_tools(dart_sdk_info)

    # Per-asset manifest: "<asset_id>\t<so_runfiles_path>".
    libs = []
    ca_lines = []
    for dep in ctx.attr.code_assets:
        info = dep[DartCodeAssetInfo]
        libs.append(info.dynamic_library)
        ca_lines.append("{}\t{}".format(
            info.asset_id,
            runfiles_path(info.dynamic_library, workspace_name),
        ))
    code_assets_manifest = ctx.actions.declare_file(ctx.label.name + ".code_assets")
    ctx.actions.write(output = code_assets_manifest, content = "\n".join(ca_lines) + "\n")

    executable, env_info, tool_runfiles = create_test_executable(
        ctx,
        ctx.attr._tool,
        env = {
            "RULES_DART_DART": runfiles_path(dart_sdk_info.dart, workspace_name),
            "RULES_DART_PKG_MANIFEST": runfiles_path(packages_manifest, workspace_name),
            "RULES_DART_MAIN": runfiles_path(ctx.file.main, workspace_name),
            "RULES_DART_GENKERNEL": runfiles_path(tools.gen_kernel_snapshot, workspace_name),
            "RULES_DART_AOTRUNTIME": runfiles_path(tools.dartaotruntime, workspace_name),
            "RULES_DART_PLATFORM": runfiles_path(tools.platform_dill, workspace_name),
            "RULES_DART_ABI": target_dart_abi(ctx),
            "RULES_DART_CODE_ASSETS": runfiles_path(code_assets_manifest, workspace_name),
        },
    )

    runfiles = ctx.runfiles(
        files = [ctx.file.main, packages_manifest, code_assets_manifest] +
                all_srcs + libs + ctx.files.data + dart_sdk_info.tool_files,
    )
    runfiles = runfiles.merge(tool_runfiles)
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        env_info,
    ]

def _dart_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    workspace_name = ctx.workspace_name

    # Collect all transitive sources from deps
    all_srcs = list(ctx.files.srcs)
    for dep in ctx.attr.deps:
        all_srcs.extend(dep[DartInfo].transitive_srcs.to_list())

    # Generate packages manifest for runtime package_config.json construction
    packages_manifest = _generate_packages_manifest(ctx, ctx.attr.deps)

    # When the test declares native code assets, the runner compiles the main
    # to a kernel (embedding the asset mapping) and runs the dill instead of
    # the source. Everything else is shared.
    if ctx.attr.code_assets:
        return _dart_test_code_assets_impl(ctx, dart_sdk_info, all_srcs, packages_manifest)

    # Resolve runfiles-relative paths for env vars
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
        "code_assets": attr.label_list(
            doc = """Native code assets (e.g. `//dart/ext/sqlite3:code_asset`) the test's \
`@Native` FFI bindings resolve against. When set, the test's `main` is compiled to a kernel \
with the code-asset mapping embedded (`gen_kernel --native-assets`) and the dill is run, so the \
Dart VM resolves the native libraries from Bazel runfiles — no `dart:ffi` ceremony in the test \
source. Each entry must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule).""",
            providers = [DartCodeAssetInfo],
        ),
        "_tool": attr.label(
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = "exec",
        ),
    }, **dict(WINDOWS_CONSTRAINT_ATTR, **DART_ABI_CONSTRAINT_ATTRS)),
    test = True,
    toolchains = ["//dart:toolchain_type"],
    doc = "Runs a Dart test file using the Dart VM.",
)
