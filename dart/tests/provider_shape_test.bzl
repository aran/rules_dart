"""Analysis-time probes locking in depset-typed provider fields and helpers.

Depset discipline is behavioral only at scale (analysis memory/CPU), so the
type contracts are asserted directly: the toolchain's `tool_files` and the
shared collectors must hand consumers depsets, not flattened lists. A
regression here silently reintroduces O(N²) analysis-phase flattening.
"""

load("//dart/private:common.bzl", "collect_transitive_srcs")

def _provider_shape_probe_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    tool_files = toolchain.dart_sdk_info.tool_files
    if type(tool_files) != "depset":
        fail("DartSdkInfo.tool_files must be a depset, got %s" % type(tool_files))

    srcs = collect_transitive_srcs(ctx.attr.deps)
    if type(srcs) != "depset":
        fail("collect_transitive_srcs must return a depset, got %s" % type(srcs))

    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(output = out, content = "ok\n")
    return [DefaultInfo(files = depset([out]))]

provider_shape_probe = rule(
    implementation = _provider_shape_probe_impl,
    attrs = {
        "deps": attr.label_list(),
    },
    toolchains = ["//dart:toolchain_type"],
)
