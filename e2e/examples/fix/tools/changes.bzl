"""Exposes the changes the `dart_analyze` aspect computes for one target.

The aspect's output groups belong to the aspect, not to the target, so a BUILD
file cannot name them; this rule applies the aspect and hands one group on as
its files, for the checks here to read.
"""

load("@rules_dart//dart:analyze.bzl", "dart_analyze")

def _dart_changes_impl(ctx):
    groups = ctx.attr.target[OutputGroupInfo]
    if not hasattr(groups, ctx.attr.output_group):
        fail("%s: the aspect has no %s for %s" % (ctx.label, ctx.attr.output_group, ctx.attr.target.label))
    return [DefaultInfo(files = getattr(groups, ctx.attr.output_group))]

dart_changes = rule(
    implementation = _dart_changes_impl,
    attrs = {
        "target": attr.label(mandatory = True, aspects = [dart_analyze]),
        "output_group": attr.string(mandatory = True),
    },
)
