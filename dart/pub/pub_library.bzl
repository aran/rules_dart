"""The two rules a pub package is built from, and the contract between them.

Pub allows packages to depend on each other — `dio` imports `dio_web_adapter`,
which imports `dio` — and Bazel does not allow a dependency cycle. So a pub
package is split in two. Its source repository holds a *member*: the package's
files and the facts it states about itself, which need nothing but its own
archive. Its library repository holds a *library* over the members of its
dependency cycle (usually just itself) and the libraries of whatever the cycle
depends on. A cycle is then one target, compiled as one, and each package in it
keeps its own name, `package_root` and language version: `package_config.json`
cannot tell it apart from packages built one per target.

`DartPackageMemberInfo` is the contract between the two. `pub_package_member`
and `pub_library` are rules_dart's member and library. A rule set whose pub
packages carry more (plugin metadata, native libraries, assets) defines its own
member rule, returning `dart_package_member_info()` beside its own providers, and
its own library rule, which reads both off its `members` and builds its
`DartInfo` with `dart_info()` (and so declares what `SUMMARY_ATTRS` says). Such a library rule may accept rules_dart's
members too, since they carry the same provider, so one cycle can mix packages
of both kinds. Which members form a cycle, and what the cycle depends on, is
planned in the library repository by `dependency_cycle()` (`pub_graph.bzl`),
which builds a cycle only where one is declared. Packages of the workspace that
depend on each other are built the same way, by `dart_package_cycle`.
"""

load("//dart:providers.bzl", "DartInfo", "DartPackageMetadataInfo")
load(
    "//dart/private:dart_package_cycle.bzl",
    _DartPackageMemberInfo = "DartPackageMemberInfo",
    _dart_package_member_info = "dart_package_member_info",
    _package_cycle_library = "package_cycle_library",
)
load("//dart/private:dart_summary.bzl", "SUMMARY_ATTRS")
load("//dart/private:dart_test_runner.bzl", _pub_test_runner = "pub_test_runner")
load("//dart/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//dart/private:runtime.bzl", "runtime_reset")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

DartPackageMemberInfo = _DartPackageMemberInfo
dart_package_member_info = _dart_package_member_info

def _pub_package_member_impl(ctx):
    return [dart_package_member_info(
        label = ctx.label,
        metadata = ctx.attr.package[DartPackageMetadataInfo],
        srcs = ctx.files.srcs,
        resources = ctx.files.resources,
    )]

pub_package_member = rule(
    implementation = _pub_package_member_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"], doc = "The package's `lib/**/*.dart`."),
        "resources": attr.label_list(allow_files = True, doc = "The rest of the package's `lib/`."),
        "package": attr.label(
            mandatory = True,
            providers = [DartPackageMetadataInfo],
            doc = "The package's `dart_package_metadata`, which states its facts.",
        ),
    },
    doc = "One pub package's files and facts, which a `pub_library` builds; not a library by itself.",
)

def _pub_library_impl(ctx):
    library = _package_cycle_library(
        ctx,
        [m[DartPackageMemberInfo] for m in ctx.attr.members],
        ctx.attr.deps,
    )
    return [library.default_info, library.info]

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
    } | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "A pub package as a library: its dependency cycle's packages, compiled as one target.",
)

# A library repository that provides `package:test` declares its runner with
# this, so generators outside rules_dart need not load a private file.
pub_test_runner = _pub_test_runner
