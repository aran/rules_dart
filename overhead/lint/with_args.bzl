"""A runnable target that is another tool, so that a target's `args` reach bazel_env."""

def _with_args_impl(ctx):
    tool = ctx.executable.tool
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = tool, is_executable = True)
    return [DefaultInfo(
        executable = out,
        runfiles = ctx.runfiles(files = [tool]).merge(ctx.attr.tool[DefaultInfo].default_runfiles),
    )]

# `args`, which every executable rule has, is what bazel_env bakes into the
# launcher it writes for a tool. Plain `alias` and multitool's own targets
# take none.
with_args = rule(
    implementation = _with_args_impl,
    attrs = {"tool": attr.label(mandatory = True, executable = True, cfg = "exec")},
    executable = True,
)
