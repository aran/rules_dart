"""The two rules a `pub.from_lock()` package is built from.

Pub allows packages to depend on each other — `dio` imports `dio_web_adapter`,
which imports `dio` — and Bazel does not allow a dependency cycle. So a locked
package is split in two. Its source repository holds a `pub_package_member`:
the package's files and the facts it states about itself, which need nothing
but its own archive. Its library repository holds a `pub_library` over the
members of its dependency cycle (usually just itself) and the libraries of
whatever the cycle depends on. A cycle is then one target, compiled as one,
and each package in it keeps its own name, `lib_root` and language version:
`package_config.json` cannot tell it apart from packages built one per target.
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:dart_info.bzl", "dart_info_packages", "package_record")
load("//dart/private:dart_library.bzl", "check_files_under_lib_root", "check_no_duplicate_srcs", "derive_lib_root", "link_hook_error")
load("//dart/private:runtime.bzl", "runtime_reset")

DartPackageMemberInfo = provider(
    doc = "One pub package's files and facts, for the `pub_library` its dependency cycle is built as.",
    fields = {
        "record": "DartPackageInfo: The package's record.",
        "srcs": "list[File]: Its Dart sources under `lib/`.",
        "resources": "list[File]: Its other files under `lib/`.",
    },
)

def _pub_package_member_impl(ctx):
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    for err in [
        check_no_duplicate_srcs(ctx.label, ctx.files.srcs),
        check_no_duplicate_srcs(ctx.label, ctx.files.resources, "resources"),
        check_files_under_lib_root(ctx.label, lib_root, ctx.files.srcs),
        check_files_under_lib_root(ctx.label, lib_root, ctx.files.resources, "resources"),
        link_hook_error(ctx.label, lib_root, ctx.file.link_hook),
    ]:
        if err != None:
            fail(err)
    return [DartPackageMemberInfo(
        record = package_record(
            label = ctx.label,
            package_name = ctx.attr.package_name,
            lib_root = lib_root,
            language_version = ctx.attr.language_version,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
            version = ctx.attr.version,
            link_hook = ctx.file.link_hook,
        ),
        srcs = ctx.files.srcs,
        resources = ctx.files.resources,
    )]

pub_package_member = rule(
    implementation = _pub_package_member_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"], doc = "The package's `lib/**/*.dart`."),
        "resources": attr.label_list(allow_files = True, doc = "The rest of the package's `lib/`."),
        "package_name": attr.string(mandatory = True, doc = "The package's name."),
        "language_version": attr.string(doc = "From the package's `environment.sdk`, as `dart_library`'s."),
        "version": attr.string(doc = "The version pub resolved, as `dart_library`'s."),
        "code_assets": attr.label_list(doc = "As `dart_library`'s."),
        "link_hook": attr.label(allow_single_file = [".dart"], doc = "As `dart_library`'s."),
        "has_unreplaced_hook": attr.string(doc = "As `dart_library`'s."),
    },
    doc = "One pub package's files and facts, which a `pub_library` builds; not a library by itself.",
)

def _pub_library_impl(ctx):
    members = [m[DartPackageMemberInfo] for m in ctx.attr.members]
    srcs = [f for m in members for f in m.srcs]
    resources = [f for m in members for f in m.resources]
    return [
        DefaultInfo(
            files = depset(srcs + resources),
            runfiles = ctx.runfiles(files = srcs + resources),
        ),
        dart_info_packages(
            packages = [m.record for m in members],
            srcs = srcs,
            resources = resources,
            deps = ctx.attr.deps,
        ),
    ]

pub_library = rule(
    implementation = _pub_library_impl,
    # A pub package cannot `select()` on the web compiler.
    cfg = runtime_reset,
    attrs = {
        "members": attr.label_list(
            providers = [DartPackageMemberInfo],
            mandatory = True,
            doc = "The packages of one dependency cycle, or the one package that is in none.",
        ),
        "deps": attr.label_list(
            providers = [DartInfo],
            doc = "The libraries of the packages the members depend on outside the cycle.",
        ),
    },
    doc = "A `pub.from_lock()` package as a library: its dependency cycle's packages, compiled as one target.",
)
