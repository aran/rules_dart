"""`executable_of`: an executable target's executable as its one file."""

def _impl(ctx):
    actual = ctx.attr.actual[DefaultInfo]
    return [DefaultInfo(
        files = depset([actual.files_to_run.executable]),
        runfiles = actual.default_runfiles,
    )]

executable_of = rule(
    implementation = _impl,
    attrs = {"actual": attr.label(executable = True, cfg = "target", mandatory = True)},
)
