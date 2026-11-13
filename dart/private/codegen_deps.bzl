"""What a codegen action reads of its `deps`: libraries, and members of a cycle.

A generator resolves what its source imports, so its target depends on the
libraries that hold it, and sees what their analysis sees: their compile
closure and `DartInfo.analysis_only` (Flutter's `sky_engine`). Inside a `dart_package_cycle` it cannot: the cycle's
library holds what the generator writes. So it reads the members' sources
instead, as build_runner reads a whole package graph, and a member holds only
its hand-written files. A codegen target that names members checks their
imports against its `deps`, as the cycle checks its own, so the generator sees
every package their sources reach.
"""

load("//dart:providers.bzl", "DartInfo")
load(
    "//dart/private:common.bzl",
    "dart_package_root_for_package",
    "merge_package_records",
    "same_package_library_dep_files",
    "synth_package_config",
)
load("//dart/private:dart_import_check.bzl", "LIBRARY_IMPORT_CHECKER_ATTRS", "dart_import_check_action")
load("//dart/private:dart_info.bzl", "analyzed_closure")
load("//dart/private:dart_package_cycle.bzl", "DartPackageMemberInfo")

visibility("//dart/...")

# The providers a codegen rule's `deps` accept.
CODEGEN_DEP_PROVIDERS = [[DartInfo], [DartPackageMemberInfo]]

# What a codegen rule checks its members' imports with.
CODEGEN_DEPS_ATTRS = LIBRARY_IMPORT_CHECKER_ATTRS

# How a codegen rule's `deps` doc names what a member gives it.
CODEGEN_MEMBER_DEPS_DOC = (
    " Inside a `dart_package_cycle`, name its `dart_package_member`s here, " +
    "every one, and the cycle's `deps`: the generator reads the members' " +
    "sources, under their own package names, and their imports are checked " +
    "against these `deps`."
)

def codegen_deps(ctx, identity, exclude_paths):
    """What a codegen action reads of `ctx.attr.deps`, and the check of its members.

    Args:
      ctx: The codegen rule's context, with `CODEGEN_DEPS_ATTRS` and
        `PORTABLE_EXEC_GROUPS`.
      identity: The rule's `resolve_package_identity` result.
      exclude_paths: Exec paths of the action's own inputs, not to be staged
        again as siblings.

    Returns:
      `struct(packages, package_config, package_files, package_root, siblings,
      validation)`: the records of every package the generator may read, the
      `package_config.json` naming them (or `None`), a depset of their files
      (or `None`), the root of the generator's own package, its files to stage
      beside the input, and the `OutputGroupInfo` checking the members'
      imports (or `None`).
    """
    libraries = [d for d in ctx.attr.deps if DartInfo in d]
    members = [d[DartPackageMemberInfo] for d in ctx.attr.deps if DartPackageMemberInfo in d]

    # What their analysis reads, not only what compiles them: a generator
    # resolves `dart:ui` as the analyzer does, through the `sky_engine` a
    # `flutter_library` below names for analysis alone.
    closure = analyzed_closure([d[DartInfo] for d in libraries])
    packages = merge_package_records(closure.packages.to_list()) + [m.package for m in members]
    srcs = depset(
        [f for m in members for f in m.srcs],
        transitive = [closure.srcs],
    )
    resources = depset(
        [f for m in members for f in m.resources],
        transitive = [closure.resources],
    )
    package_config, package_files = synth_package_config(ctx, packages, srcs, resources)

    # The package root from the records read, which holds even when the rule's
    # Bazel package is not the Dart package's root (`//myapp/lib:codegen` for
    # package `myapp`).
    package_root = identity.package_root
    from_deps = dart_package_root_for_package(packages, identity.package_name)
    if identity.metadata == None and from_deps != None:
        package_root = from_deps

    # The generator's own package's files that `deps` hold, staged beside the
    # input so builders (stacked, mockito, cross-file resolvers) see them
    # through the Resolver, `findAssets` and `readAsString`.
    siblings, _ = same_package_library_dep_files(
        packages,
        depset(transitive = [srcs, resources]),
        identity.package_name,
        exclude_paths = exclude_paths,
    )

    validation = None
    checker = ctx.attr._import_checker[DefaultInfo].files_to_run
    if members and checker.executable != None:
        checked = dart_import_check_action(
            ctx,
            kernel_tool = checker,
            name = ctx.label.name + ".members",
            srcs = [f for m in members for f in m.srcs],
            own = [m.package for m in members],
            deps = libraries,
            generator_input = True,
        )
        if checked.validation:
            validation = OutputGroupInfo(_validation = depset([checked.validation]))
    return struct(
        packages = packages,
        package_config = package_config,
        package_files = package_files,
        package_root = package_root,
        siblings = siblings,
        validation = validation,
    )
