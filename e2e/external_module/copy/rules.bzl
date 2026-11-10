"""A rule defined outside rules_dart that colocates packages with its helpers."""

load(
    "@rules_dart//dart:providers.bzl",
    "DartInfo",
)
load(
    "@rules_dart//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "colocate_packages",
)

def _colocate_impl(ctx):
    packages = collect_packages(ctx.attr.deps)
    srcs = collect_transitive_srcs(ctx.attr.deps).to_list()
    _, srcs2 = colocate_packages(ctx, packages, srcs)
    return [DefaultInfo(files = depset(srcs2))]

colocate = rule(
    implementation = _colocate_impl,
    attrs = {"deps": attr.label_list(providers = [DartInfo])},
    # The exported list, passed straight to `rule()`, as its docs instruct.
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
)
