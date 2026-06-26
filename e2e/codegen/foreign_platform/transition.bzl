"""Minimal platform-transition wrapper for non-executable targets.

`platform_data` (rules_platform) only transitions *executable* targets, but
codegen rules emit plain files. `build_under_platform` forwards a dep's files
while transitioning that dep onto a fixed target platform, so a `build_test` can
assert the dep builds under a platform with no registered Dart toolchain.
"""

def _platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.platform]}

_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _build_under_platform_impl(ctx):
    files = depset(transitive = [t[DefaultInfo].files for t in ctx.attr.target])
    return [DefaultInfo(files = files)]

build_under_platform = rule(
    implementation = _build_under_platform_impl,
    attrs = {
        "target": attr.label_list(
            cfg = _platform_transition,
            mandatory = True,
            doc = "Targets to build under `platform`; their files are forwarded.",
        ),
        "platform": attr.string(
            mandatory = True,
            doc = "Label of the target platform to transition `target` onto.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
