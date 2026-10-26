"""Checking a target's imports against its own dependencies.

Bazel's discipline on top of Dart's: a library may import only what its own
`deps` provide (strict deps), a file of its own package only if it or one of
its dependencies holds it, and — unless the `dart_layering_check` feature is
off, as rules_cc's `layering_check` — a package only if a *direct* dependency
provides it: one reached only through a dependency's dependency stops being
there when that dependency drops it.

The checks read import directives and nothing compiled, so each runs as a
small validation action per library: `dart_import_check_aspect` walks an
executable's dependencies, and the executable puts the results in its
`_validation` output group, so building a `dart_test` or a `dart_binary` runs
every check its libraries need. Conditional imports are checked on every
branch, so the result is the same on every platform.

Another repository's targets are not checked: their dependencies are their
own (a pub package's are generated from its pubspec), and a file of one that
imports what none of them provides fails only a program that reaches it.
"""

load("//dart:providers.bzl", "DartImportCheckInfo", "DartInfo")
load("//dart/private:common.bzl", "PATH_MAPPING", "add_kernel_roots", "own_package_record")
load(
    "//dart/private:dart_deps.bzl",
    "direct_dart_deps",
    "exported_libraries",
    "forwarded_library",
    "propagated_attrs",
    "propagated_toolchains",
    "reached_targets",
)
load("//dart/private:dart_module.bzl", "KERNEL_TOOL_ATTR", "kernel_package_config")
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS")

LAYERING_CHECK_FEATURE = "dart_layering_check"

def _package_name(pkg):
    return pkg.package_name

def _path(f):
    return f.path

def _add_layering_args(args, deps, indirect_deps):
    """The packages a target may import: its direct dependencies'.

    A dependency without sources of its own (a façade re-exporting its
    `deps`) stands for everything it reaches, and the target's
    `DartInfo.indirect_deps` (a generator's imports) are accepted by the
    package each of them has in its dependent's `DartInfo.deps`.
    """
    args.add("--check-layering")
    facades = []
    for dep in deps:
        if DartInfo not in dep:
            continue
        dep_info = dep[DartInfo]
        if dep_info.package_name:
            args.add("--direct-package", dep_info.package_name)
        if not getattr(dep_info, "srcs", None):
            facades.append(dep_info.transitive_packages)
        for wanted in indirect_deps:
            package = getattr(dep_info, "deps", {}).get(wanted)
            if package:
                args.add("--direct-package", package)
    args.add_all(depset(transitive = facades), before_each = "--direct-package", map_each = _package_name, uniquify = True)

def dart_import_check_action(ctx, kernel_tool, name, srcs, own_package, deps, indirect_deps = []):
    """Checks the imports of `srcs` against `deps`, as a validation action.

    Args:
      ctx: The rule or aspect context.
      kernel_tool: The `kernel_tool` executable.
      name: Basename for the result, unique in the package.
      srcs: The target's own Dart sources (or source directories).
      own_package: The `DartPackageInfo` they belong to, or `None`.
      deps: The targets they may import from, each providing `DartInfo`.
      indirect_deps: Labels from `DartInfo.indirect_deps`.

    Returns:
      The result File to put in `_validation`, or `None` when there is nothing
      to check: no Dart sources, or a target of another repository.
    """
    srcs = [f for f in srcs if f.is_directory or f.extension == "dart"]
    if not srcs or ctx.label.workspace_name:
        return None
    dep_infos = [dep[DartInfo] for dep in deps if DartInfo in dep]
    packages = depset(
        [own_package] if own_package != None else [],
        transitive = [info.transitive_packages for info in dep_infos],
    )
    dep_srcs = depset(transitive = [info.transitive_srcs for info in dep_infos])

    # Package records by name, the target's own first, for mapping files to
    # `package:` URIs; two hubs supplying one package agree on its name.
    by_name = {}
    for pkg in packages.to_list():
        by_name.setdefault(pkg.package_name, pkg)
    package_config = ctx.actions.declare_file(name + ".import_check_package_config.json")
    ctx.actions.write(package_config, kernel_package_config(by_name.values()))
    result = ctx.actions.declare_file(name + ".import_check")

    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--label", str(ctx.label))
    args.add("--package-config", package_config)
    if own_package != None:
        args.add("--package-name", own_package.package_name)
        args.add("--lib-root", own_package.lib_root)

    # The result is in the output directory a generated dependency is read from.
    add_kernel_roots(args, "--multi-root", srcs + [result])
    args.add_all(srcs, before_each = "--src", expand_directories = False)
    args.add_all(dep_srcs, before_each = "--dep-file", map_each = _path, expand_directories = False)
    args.add_all(packages, before_each = "--available-package", map_each = _package_name, uniquify = True)
    if LAYERING_CHECK_FEATURE not in ctx.disabled_features:
        _add_layering_args(args, deps, indirect_deps)
    args.add("--output", result)

    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["check", args],
        inputs = depset(srcs + [package_config], transitive = [dep_srcs]),
        outputs = [result],
        mnemonic = "DartImportCheck",
        exec_group = PORTABLE,
        progress_message = "Checking Dart imports of %{label}",
        execution_requirements = PATH_MAPPING,
    )
    return result

def _import_check_aspect_impl(target, ctx):
    reached = reached_targets(ctx, DartImportCheckInfo)
    if DartInfo not in target:
        return [DartImportCheckInfo(stamps = depset(), exported = exported_libraries(reached))]
    info = target[DartInfo]
    forwarded = forwarded_library(info, reached)
    if forwarded != None:
        return [forwarded[DartImportCheckInfo]]
    direct = direct_dart_deps(ctx, info, reached, DartImportCheckInfo)
    result = dart_import_check_action(
        ctx,
        kernel_tool = ctx.executable._kernel_tool,
        name = ctx.label.name,
        srcs = getattr(info, "srcs", []),
        own_package = own_package_record(info),
        deps = direct,
        indirect_deps = getattr(info, "indirect_deps", []),
    )
    return [DartImportCheckInfo(
        stamps = depset([result] if result else [], transitive = [dep[DartImportCheckInfo].stamps for dep in direct]),
        exported = {},
    )]

dart_import_check_aspect = aspect(
    implementation = _import_check_aspect_impl,
    attr_aspects = propagated_attrs,
    toolchains_aspects = propagated_toolchains,
    exec_groups = PORTABLE_EXEC_GROUPS,
    attrs = KERNEL_TOOL_ATTR,
    doc = "Checks the imports of every library an executable depends on; see `dart_import_check.bzl`.",
)

def import_check_validation(ctx, kernel_tool, srcs, own_package, deps):
    """The `_validation` output group of an executable: its own files' check and its libraries'.

    Args:
      ctx: The executable's rule context; its `deps` carry the aspect.
      kernel_tool: The `kernel_tool` executable.
      srcs: The executable's own source Files.
      own_package: The `DartPackageInfo` it states, or `None`.
      deps: Its `deps`.

    Returns:
      A depset of result Files.
    """
    own = dart_import_check_action(ctx, kernel_tool, ctx.label.name, srcs, own_package, deps)
    return depset(
        [own] if own else [],
        transitive = [dep[DartImportCheckInfo].stamps for dep in deps if DartImportCheckInfo in dep],
    )
