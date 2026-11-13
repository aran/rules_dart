"""A downstream member kind and library rule, over rules_dart's public pub surface.

`fancy_member` is a pub package carrying data rules_dart knows nothing about (a
greeting, standing in for a Flutter plugin's metadata and native libraries).
`fancy_library` builds a dependency cycle of members, its own or rules_dart's
`pub_package_member`, and carries that data through to the library: each
member's own providers are on its `members`, so nothing has to pass through
rules_dart to survive. `fancy_native` stands in for a plugin's per-platform
library, which depends on the native libraries of whatever the cycle depends
on.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo", "DartPackageMetadataInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "PORTABLE_EXEC_GROUPS", "SUMMARY_ATTRS", "dart_analyzable_info", "dart_info", "runtime_reset")
load("@rules_dart//dart/pub:pub_library.bzl", "DartPackageMemberInfo", "dart_package_member_info")

FancyMemberInfo = provider(
    doc = "What a fancy member carries beyond its Dart package.",
    fields = {"greeting": "str"},
)

FancyInfo = provider(
    doc = "A fancy library's greetings: its own members', and every one beneath it.",
    fields = {
        "greetings": "dict[str, str]: Each of this library's own members with a greeting, by package name.",
        "transitive_greetings": "depset[str]: `<package>=<greeting>`, for this library and every library beneath.",
    },
)

def _fancy_member_impl(ctx):
    return [
        dart_package_member_info(
            label = ctx.label,
            metadata = ctx.attr.package[DartPackageMetadataInfo],
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
        ),
        FancyMemberInfo(greeting = ctx.attr.greeting),
    ]

fancy_member = rule(
    implementation = _fancy_member_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".dart"]),
        "resources": attr.label_list(allow_files = True),
        "package": attr.label(mandatory = True, providers = [DartPackageMetadataInfo]),
        "greeting": attr.string(mandatory = True),
    },
)

def _fancy_library_impl(ctx):
    infos = [m[DartPackageMemberInfo] for m in ctx.attr.members]
    srcs = [f for m in infos for f in m.srcs]
    resources = [f for m in infos for f in m.resources]
    packages = [m.package for m in infos]
    greetings = {
        m[DartPackageMemberInfo].package.package_name: m[FancyMemberInfo].greeting
        for m in ctx.attr.members
        if FancyMemberInfo in m
    }
    return [
        DefaultInfo(
            files = depset(srcs + resources),
            runfiles = ctx.runfiles(files = srcs + resources),
        ),
        dart_info(
            ctx = ctx,
            packages = packages,
            srcs = srcs,
            resources = resources,
            deps = ctx.attr.deps,
            analysis_deps = [ctx.attr._engine],
        ),
        # The analyzer sees one more package than the compiler, as
        # `flutter_library`'s `sky_engine`.
        dart_analyzable_info(
            label = ctx.label,
            packages = packages,
            deps = ctx.attr.deps + [ctx.attr._engine],
            srcs = srcs,
            resources = resources,
        ),
        FancyInfo(
            greetings = greetings,
            transitive_greetings = depset(
                ["%s=%s" % item for item in greetings.items()],
                transitive = [d[FancyInfo].transitive_greetings for d in ctx.attr.deps if FancyInfo in d],
            ),
        ),
    ]

fancy_library = rule(
    implementation = _fancy_library_impl,
    cfg = runtime_reset,
    attrs = {
        "members": attr.label_list(providers = [DartPackageMemberInfo], mandatory = True),
        "deps": attr.label_list(providers = [DartInfo]),
        "_engine": attr.label(default = Label("//fixtures/pub_member_kind/engine"), providers = [DartInfo]),
    } | SUMMARY_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
)

def _fancy_native_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".native")
    ctx.actions.write(out, str(ctx.label) + "\n")
    return [DefaultInfo(files = depset([out], transitive = [d[DefaultInfo].files for d in ctx.attr.deps]))]

fancy_native = rule(
    implementation = _fancy_native_impl,
    attrs = {"deps": attr.label_list()},
)
