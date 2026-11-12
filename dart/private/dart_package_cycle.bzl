"""Packages that depend on each other, built as one library.

Dart allows packages to import each other in a cycle, and Bazel allows no
dependency cycle between targets. So each package of a cycle is a *member*,
which holds its files and names its declaration but is no library, and one
library builds every member. Each package keeps its own name, `package_root`
and language version, so `package_config.json` cannot tell it apart from
packages built one per target.

`dart_package_cycle` is that library for packages of the workspace. It checks
what its members import, and that they are exactly one cycle. `pub_library`
(`//dart/pub:pub_library.bzl`) is the same library for a pub cycle, which
`pub.cycle()` declares and whose files are another repository's, so it checks
neither. Both build on `package_cycle_library()`.

What generators write for a member's sources is the cycle's, in its `srcs`, not
the member's. A generator resolves what its source imports, which in a cycle is
every member, so it reads the members' sources (`codegen_deps.bzl`); a member
holding its generated files would depend on the generator that reads it.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "codegen_identity_error", "package_identity_attrs")
load("//dart/private:dart_import_check.bzl", "LIBRARY_IMPORT_CHECKER_ATTRS", "UNUSED_DEPS_OUTPUT_GROUP", "dart_import_check_action")
load("//dart/private:dart_info.bzl", "package_lib_prefix")
load("//dart/private:dart_library.bzl", "LIBRARY_SOURCE_ATTRS", "check_no_duplicate_srcs", "checked_package_info", "library_sources")
load("//dart/private:dart_summary.bzl", "SUMMARY_ATTRS", "dart_info")
load("//dart/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//dart/private:runtime.bzl", "RUNTIME_INDEPENDENT_ATTR", "runtime_reset_when_independent")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

visibility("//dart/...")

DartPackageMemberInfo = provider(
    doc = """One package's files and facts, for the library its dependency cycle is built as.

Not a `DartInfo`: a member is not a library, and a `deps` attribute refuses \
one. Build it with `dart_package_member_info()`, which checks the files and \
makes the package record. `pub_package_member` and `dart_package_member` \
return it.""",
    fields = {
        "package": "DartPackageInfo: The package's record, for `dart_info(packages = ...)`.",
        "srcs": "list[File]: Its Dart sources under `lib/`, for `dart_info(srcs = ...)`.",
        "resources": "list[File]: Its other files under `lib/`, for `dart_info(resources = ...)`.",
    },
)

def dart_package_member_info(label, metadata, srcs = [], resources = []):
    """Builds the `DartPackageMemberInfo` of a package declared by a `dart_package_metadata`.

    For a member rule: rules_dart's `pub_package_member`, or another rule set's
    that returns this beside providers of its own. The package's facts are its
    declaration's, and its root is the declaration's. Fails when a file is not
    under the package's `lib/` or two resolve to the same path.

    Args:
      label: The member's label.
      metadata: The `DartPackageMetadataInfo` of the package's
        `dart_package_metadata`.
      srcs: The package's `lib/**/*.dart` Files.
      resources: The rest of its `lib/` Files.

    Returns:
      A `DartPackageMemberInfo`.
    """
    return DartPackageMemberInfo(
        package = checked_package_info(label, metadata, srcs, resources),
        srcs = srcs,
        resources = resources,
    )

def package_cycle_library(ctx, members, deps, data = [], generated = []):
    """The library of the packages of one dependency cycle.

    Args:
      ctx: The library's rule context, with `SUMMARY_ATTRS`, `PORTABLE_EXEC_GROUPS`
        and `COPY_TO_DIRECTORY_TOOLCHAINS`.
      members: The members' `DartPackageMemberInfo`.
      deps: The libraries the members depend on outside the cycle.
      data: Files the packages need at run time.
      generated: Dart files generated for the members' sources, each under
        one member's `lib/`.

    Returns:
      `struct(default_info, info)`: the library's `DefaultInfo` and `DartInfo`.
    """
    srcs = [f for m in members for f in m.srcs] + generated
    resources = [f for m in members for f in m.resources]
    info = dart_info(
        ctx = ctx,
        packages = [m.package for m in members],
        srcs = srcs,
        resources = resources,
        deps = deps,
        data = data,
    )
    runfiles = ctx.runfiles(files = srcs + resources)
    return struct(
        default_info = DefaultInfo(
            files = depset(srcs + resources),
            runfiles = runfiles.merge(info.runfiles) if info.runfiles != None else runfiles,
        ),
        info = info,
    )

def _dart_package_member_impl(ctx):
    sources = library_sources(ctx)
    return [
        DartPackageMemberInfo(
            package = sources.package.record,
            srcs = sources.srcs,
            resources = sources.resources,
        ),
        DefaultInfo(files = depset(sources.srcs + sources.resources)),
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            extensions = ["dart"],
        ),
    ]

dart_package_member = rule(
    implementation = _dart_package_member_impl,
    attrs = LIBRARY_SOURCE_ATTRS | package_identity_attrs(),
    doc = """One package of a dependency cycle: its files under `lib/` and the \
`dart_package_metadata` that declares it. Not a library by itself, so nothing \
depends on it but the `dart_package_cycle` that builds it, and the codegen \
targets that read its sources. Its files are checked as a `dart_library`'s are. \
What generators write for them goes in the cycle's `srcs`.""",
)

def _member_holding(members, f):
    """The member whose `lib/` holds `f`, the deepest when roots nest, or None."""
    best = None
    for m in members:
        if f.short_path.startswith(package_lib_prefix(m.package.package_root)):
            if best == None or len(m.package.package_root) > len(best.package.package_root):
                best = m
    return best

def _check_generated(ctx, members):
    """Fails unless each of `srcs` is part of a member, as its generator says."""
    for target in ctx.attr.srcs:
        for f in target.files.to_list():
            m = _member_holding(members, f)
            if m == None:
                fail(("%s: `srcs` holds `%s`, which is under the `lib/` of no member. " +
                      "A generated file is part of the package whose sources it was " +
                      "generated from: write it beside them.") % (ctx.label, f.short_path))
            pkg = m.package
            err = codegen_identity_error(
                ctx.label,
                [target],
                pkg.package_name,
                struct(label = pkg.metadata) if pkg.metadata != None else None,
            )
            if err != None:
                fail(err)
    err = check_no_duplicate_srcs(ctx.label, [f for m in members for f in m.srcs] + ctx.files.srcs)
    if err != None:
        fail(err)

def _dart_package_cycle_impl(ctx):
    members = [m[DartPackageMemberInfo] for m in ctx.attr.members]
    seen = {}
    for target, m in zip(ctx.attr.members, members):
        name = m.package.package_name
        if name in seen:
            fail("%s: `members` names package `%s` twice, in %s and %s. A package is in one member." % (
                ctx.label,
                name,
                seen[name],
                target.label,
            ))
        seen[name] = target.label
    if len(members) < 2:
        fail(("%s: a dependency cycle is of several packages, and `members` names one. " +
              "Build a package that is in no cycle as a `dart_library`.") % ctx.label)
    _check_generated(ctx, members)
    library = package_cycle_library(ctx, members, ctx.attr.deps, ctx.attr.data, ctx.files.srcs)
    validation = []
    report = []
    checker = ctx.attr._import_checker[DefaultInfo].files_to_run
    if checker.executable != None:
        checked = dart_import_check_action(
            ctx,
            kernel_tool = checker,
            name = ctx.label.name,
            srcs = library.info.srcs,
            own = [m.package for m in members],
            deps = ctx.attr.deps,
            check_cycle = True,
            check_unused = True,
        )
        if checked.validation:
            validation.append(checked.validation)
        if checked.report:
            report.append(checked.report)
    return [
        library.default_info,
        library.info,
        coverage_common.instrumented_files_info(
            ctx,
            dependency_attributes = ["members", "deps"],
            extensions = ["dart"],
        ),
        OutputGroupInfo(**{
            "_validation": depset(validation),
            UNUSED_DEPS_OUTPUT_GROUP: depset(report),
        }),
    ]

dart_package_cycle = rule(
    implementation = _dart_package_cycle_impl,
    cfg = runtime_reset_when_independent,
    attrs = {
        "members": attr.label_list(
            providers = [DartPackageMemberInfo],
            mandatory = True,
            doc = "The `dart_package_member` of each package of the cycle, every one of them.",
        ),
        "deps": attr.label_list(
            providers = [DartInfo],
            doc = "The libraries the members import outside the cycle.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = """What generators write for the members' sources: the codegen \
targets whose outputs are parts of the members' libraries. Each file is part of \
the member whose `lib/` holds it. They are the cycle's rather than the member's \
because a generator in a cycle reads the members (`dart_codegen.deps`).""",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Files the packages need at run time, outside their `lib/`, as a `dart_library`'s `data`.",
        ),
    } | RUNTIME_INDEPENDENT_ATTR | LIBRARY_IMPORT_CHECKER_ATTRS | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = """Packages that import each other, built as one library.

Dart allows a cycle between packages and Bazel allows none between targets, so \
the packages of a cycle are one target. Each keeps its own name, root and \
language version. Depend on it wherever you would depend on one of its \
packages. Its `_validation` output group checks what the members import \
against `deps`, as a `dart_library`'s does, and that the members are exactly \
one cycle: a member that imports none of the others, or that none of them \
imports, fails the build, naming what to change.""",
)
