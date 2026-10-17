"""A rule in an external module that calls `colocate_packages` and `colocate_entrypoint`."""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "colocate_entrypoint",
    "colocate_packages",
)

def _colocated_sources_impl(ctx):
    packages = collect_packages(ctx.attr.deps)
    all_srcs = collect_transitive_srcs(ctx.attr.deps).to_list()
    packages2, srcs2 = colocate_packages(ctx, packages, all_srcs)
    main_input, main_arg, extra_inputs = colocate_entrypoint(ctx, ctx.file.main, ctx.files.srcs)
    if len(packages2) != 1 or not packages2[0].lib_root.endswith(".pkgsrcs"):
        fail("expected one assembled .pkgsrcs package, got: %s" % packages2)
    if not main_input.is_directory or not main_arg.endswith("/lib/message.dart") or extra_inputs:
        fail("expected assembled .entrysrcs entrypoint, got: %s %s %s" % (main_input, main_arg, extra_inputs))
    return [DefaultInfo(files = depset(srcs2 + [main_input]))]

colocated_sources = rule(
    implementation = _colocated_sources_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "main": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True),
    },
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
)
