"""Checking a target's imports against its own dependencies.

Bazel's discipline on top of Dart's: a library may import only what its own
`deps` provide (strict deps), a file of its own package only if it or one of
its dependencies holds it, and — unless the `dart_layering_check` feature is
off, as rules_cc's `layering_check` — a package only if a *direct* dependency
provides it: one reached only through a dependency's dependency stops being
there when that dependency drops it.

Beyond the dependencies, a file may name only what the compiler can reach
through declared inputs, judged as the compiler spells it: a `dart:` library,
a `package:` URI that stays inside its package and that a dependency provides,
or a file the target holds (a part) or the target or its dependencies hold (an
import); the empty URI (`import '' as self;`) names the library itself. A
`file:` URI, another scheme, a URI with a query or fragment or a relative path
into a package's `lib/` from outside it (each a second copy of the library), or
a path out of the workspace is refused, with the spelling to use instead.

The checks read directives and nothing compiled, so each runs as a small
validation action per library. A `dart_library` checks itself, in its own
`_validation` output group, as rules_cc ties `layering_check` to the target:
any build of the library runs it, an analysis included. An executable checks
its own files, and `dart_import_check_aspect` reaches the libraries of other
rules (a `dart_proto_library`, say) that cannot check themselves, so building a
`dart_test` or a `dart_binary` runs every check its libraries need.
Conditional imports are checked on every branch, so the result is the same on
every platform.

`kernel_tool`, which runs the check, is itself built from libraries: the rules
that build it (`dart_tool_binary`) reach their dependencies through
`without_import_check`, under which a library has no checker to depend on.

Another repository's targets are not checked: their dependencies are their
own (a pub package's are generated from its pubspec), and a file of one that
imports what none of them provides fails only a program that reaches it.
"""

load("//dart:providers.bzl", "DartImportCheckInfo", "DartInfo")
load("//dart/private:common.bzl", "PATH_MAPPING", "add_kernel_roots", "merge_package_records", "own_packages")
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

visibility("//dart/...")

LAYERING_CHECK_FEATURE = "dart_layering_check"

_IMPORT_CHECK = str(Label("//dart/private:import_check"))

def _without_import_check_impl(_settings, _attr):
    return {_IMPORT_CHECK: False}

without_import_check = transition(
    implementation = _without_import_check_impl,
    inputs = [],
    outputs = [_IMPORT_CHECK],
)

# What a `dart_library` checks its imports with: `kernel_tool`, or nothing
# under `without_import_check`, where `kernel_tool` is what is being built.
LIBRARY_IMPORT_CHECKER_ATTRS = {
    "_import_checker": attr.label(
        default = Label("//dart/private:import_checker"),
        cfg = config.exec(PORTABLE),
    ),
}

def library_import_check(ctx, own):
    """A `dart_library`'s `_validation` output group: the check of its own files.

    Args:
      ctx: The library's rule context, with `LIBRARY_IMPORT_CHECKER_ATTRS` and
        `PORTABLE_EXEC_GROUPS`.
      own: The library's `DartPackageInfo` records (`DartInfo.packages`).

    Returns:
      A list holding the `OutputGroupInfo`, or empty when nothing is checked.
    """
    checker = ctx.attr._import_checker[DefaultInfo].files_to_run
    if checker.executable == None:
        return []
    result = dart_import_check_action(
        ctx,
        kernel_tool = checker,
        name = ctx.label.name,
        srcs = ctx.files.srcs + ctx.files.srcs_dir,
        own = own,
        deps = ctx.attr.deps,
    )
    return [OutputGroupInfo(_validation = depset([result]))] if result else []

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
        for pkg in own_packages(dep_info):
            args.add("--direct-package", pkg.package_name)
        if not getattr(dep_info, "srcs", None):
            facades.append(dep_info.transitive_packages)
        for wanted in indirect_deps:
            for package in getattr(dep_info, "deps", {}).get(wanted, ()):
                args.add("--direct-package", package)
    args.add_all(depset(transitive = facades), before_each = "--direct-package", map_each = _package_name, uniquify = True)

def dart_import_check_action(ctx, kernel_tool, name, srcs, own, deps, indirect_deps = []):
    """Checks the imports of `srcs` against `deps`, as a validation action.

    Args:
      ctx: The rule or aspect context.
      kernel_tool: The `kernel_tool` executable, a File or its `FilesToRunProvider`.
      name: Basename for the result, unique in the package.
      srcs: The target's own Dart sources (or source directories).
      own: The `DartPackageInfo` records they belong to; empty for an
        executable stating no package.
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
        own,
        transitive = [info.transitive_packages for info in dep_infos],
    )
    dep_srcs = depset(transitive = [info.transitive_srcs for info in dep_infos])

    # Package records by name, the target's own first, for mapping files to
    # `package:` URIs; two hubs supplying one package agree on its name. A
    # package config is assembled here for every library, so the merge's
    # agreement check refuses two declarations of one package where a library
    # first reaches both, not only in the programs that use it.
    by_name = {pkg.package_name: pkg for pkg in merge_package_records(packages.to_list())}
    package_config = ctx.actions.declare_file(name + ".import_check_package_config.json")
    ctx.actions.write(package_config, kernel_package_config(by_name.values()))
    result = ctx.actions.declare_file(name + ".import_check")

    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--label", str(ctx.label))
    args.add("--package-config", package_config)
    for pkg in own:
        args.add("--package-name", pkg.package_name)
        args.add("--package-root", pkg.package_root)

    # Every directory a file is read from, the result's included: a
    # dependency built in another configuration (a test's `defines`) has its
    # generated files in another output directory.
    add_kernel_roots(args, "--multi-root", depset(srcs + [result], transitive = [dep_srcs]))
    args.add_all(srcs, before_each = "--src", expand_directories = False)
    args.add_all(dep_srcs, before_each = "--dep-file", map_each = _path, expand_directories = False)
    args.add_all(packages, before_each = "--available-package", map_each = _package_name, uniquify = True)
    if LAYERING_CHECK_FEATURE not in ctx.disabled_features:
        _add_layering_args(args, deps, indirect_deps)
    args.add("--output", result)

    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["check", args],
        # The check names a dependency's file by its path alone, so only a
        # directory, which it lists, is an input: a body edit in a dependency
        # does not rerun the check of everything above it.
        inputs = depset(
            srcs + [package_config],
            transitive = [getattr(info, "transitive_src_dirs", depset()) for info in dep_infos],
        ),
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
    if ctx.rule.kind == "dart_library":
        # It checks itself: its `_validation` group holds the result.
        groups = target[OutputGroupInfo] if OutputGroupInfo in target else None
        results = [groups._validation] if hasattr(groups, "_validation") else []
    else:
        result = dart_import_check_action(
            ctx,
            kernel_tool = ctx.executable._kernel_tool,
            name = ctx.label.name,
            srcs = getattr(info, "srcs", []),
            own = own_packages(info),
            deps = direct,
            indirect_deps = getattr(info, "indirect_deps", []),
        )
        results = [depset([result])] if result else []
    return [DartImportCheckInfo(
        stamps = depset(transitive = results + [dep[DartImportCheckInfo].stamps for dep in direct]),
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
    result = dart_import_check_action(ctx, kernel_tool, ctx.label.name, srcs, [own_package] if own_package != None else [], deps)
    return depset(
        [result] if result else [],
        transitive = [dep[DartImportCheckInfo].stamps for dep in deps if DartImportCheckInfo in dep],
    )
