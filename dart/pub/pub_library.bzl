"""The two rules a pub package is built from, and the contract between them.

Pub allows packages to depend on each other — `dio` imports `dio_web_adapter`,
which imports `dio` — and Bazel does not allow a dependency cycle. So a pub
package is split in two. Its source repository holds a *member*: the package's
files and the facts it states about itself, which need nothing but its own
archive. Its library repository holds a *library* over the members of its
dependency cycle (usually just itself) and the libraries of whatever the cycle
depends on. A cycle is then one target, compiled as one, and each package in it
keeps its own name, `lib_root` and language version: `package_config.json`
cannot tell it apart from packages built one per target.

`DartPackageMemberInfo` is the contract between the two. `pub_package_member`
and `pub_library` are rules_dart's member and library. A rule set whose pub
packages carry more (plugin metadata, native libraries, assets) defines its own
member rule, returning `dart_package_member_info()` beside its own providers, and
its own library rule, which reads both off its `members` and builds its
`DartInfo` with `dart_info()`. Such a library rule may accept rules_dart's
members too, since they carry the same provider, so one cycle can mix packages
of both kinds. Which members form a cycle, and what the cycle depends on, is
planned in the library repository by `dependency_cycle()` (`pub_graph.bzl`).
"""

load("//dart:providers.bzl", "DartInfo")
load("//dart/private:dart_info.bzl", "dart_info", "dart_package_info")
load("//dart/private:dart_library.bzl", "check_files_under_lib_root", "check_no_duplicate_srcs", "link_hook_error", "package_root")
load("//dart/private:dart_test_runner.bzl", _pub_test_runner = "pub_test_runner")
load("//dart/private:runtime.bzl", "runtime_reset")

DartPackageMemberInfo = provider(
    doc = """One pub package's files and facts, for the library its dependency cycle is built as.

Not a `DartInfo`: a member is not a library, and a `deps` attribute refuses \
one. Build it with `dart_package_member_info()`, which checks the files and \
makes the package record.""",
    fields = {
        "package": "DartPackageInfo: The package's record, for `dart_info(packages = ...)`.",
        "srcs": "list[File]: Its Dart sources under `lib/`, for `dart_info(srcs = ...)`.",
        "resources": "list[File]: Its other files under `lib/`, for `dart_info(resources = ...)`.",
    },
)

def dart_package_member_info(
        label,
        package_name,
        language_version,
        srcs = [],
        resources = [],
        code_assets = [],
        version = "",
        link_hook = None,
        has_unreplaced_hook = "",
        license_file = None):
    """Builds the `DartPackageMemberInfo` of a pub package rooted at `label`'s Bazel package.

    For a member rule: rules_dart's `pub_package_member`, or another rule set's
    that returns this beside providers of its own. Fails when a file is not
    under the package's `lib/`, two resolve to the same path, or the link hook
    is not the package's `hook/link.dart`.

    Args:
      label: The member's label. Its Bazel package is the pub package's root.
      package_name: The package's name.
      language_version: From the package's `environment.sdk`, as for
        `dart_package_info()`; "" when it states none.
      srcs: The package's `lib/**/*.dart` Files.
      resources: The rest of its `lib/` Files.
      code_assets: Targets providing `DartCodeAssetInfo` replacing its build
        hook.
      version: The version pub resolved, or "".
      link_hook: Its `hook/link.dart` File, or None.
      has_unreplaced_hook: Path of a build hook nothing replaces, or "".
      license_file: Its license text File, or None: the root `NOTICES` if it
        has one, else its `LICENSE`, as `find_pub_license_file()` finds them.

    Returns:
      A `DartPackageMemberInfo`.
    """
    root = package_root(label.workspace_root, label.package, srcs + resources)
    if root.error != None:
        fail("%s: %s" % (label, root.error))
    lib_root = root.root
    for err in [
        check_no_duplicate_srcs(label, srcs),
        check_no_duplicate_srcs(label, resources, "resources"),
        check_files_under_lib_root(label, lib_root, srcs),
        check_files_under_lib_root(label, lib_root, resources, "resources"),
        link_hook_error(label, lib_root, link_hook),
    ]:
        if err != None:
            fail(err)
    return DartPackageMemberInfo(
        package = dart_package_info(
            label = label,
            package_name = package_name,
            lib_root = lib_root,
            language_version = language_version,
            code_assets = code_assets,
            has_unreplaced_hook = has_unreplaced_hook,
            version = version,
            link_hook = link_hook,
            license_file = license_file,
        ),
        srcs = srcs,
        resources = resources,
    )

def _pub_package_member_impl(ctx):
    return [dart_package_member_info(
        label = ctx.label,
        package_name = ctx.attr.package_name,
        language_version = ctx.attr.language_version,
        srcs = ctx.files.srcs,
        resources = ctx.files.resources,
        code_assets = ctx.attr.code_assets,
        version = ctx.attr.version,
        link_hook = ctx.file.link_hook,
        has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
        license_file = ctx.file.license_file,
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
        "license_file": attr.label(allow_single_file = True, doc = "As `dart_library`'s."),
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
        dart_info(
            label = ctx.label,
            packages = [m.package for m in members],
            srcs = srcs,
            resources = resources,
            deps = ctx.attr.deps,
        ),
    ]

pub_library = rule(
    implementation = _pub_library_impl,
    # A pub package cannot `select()` on the runtime.
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
    doc = "A pub package as a library: its dependency cycle's packages, compiled as one target.",
)

# A library repository that provides `package:test` declares its runner with
# this, so generators outside rules_dart need not load a private file.
pub_test_runner = _pub_test_runner
