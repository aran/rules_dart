"""A rule that colocates the packages of its deps, as a rule of a consumer would."""

load("//dart:providers.bzl", "DartInfo")
load(
    "//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "colocate_packages",
)

def _colocated_impl(ctx):
    _, srcs = colocate_packages(
        ctx,
        collect_packages(ctx.attr.deps),
        collect_transitive_srcs(ctx.attr.deps).to_list(),
    )
    return [DefaultInfo(files = depset(srcs))]

colocated = rule(
    implementation = _colocated_impl,
    attrs = {"deps": attr.label_list(providers = [DartInfo])},
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "The sources of the packages of `deps`, each assembled into one directory.",
)
