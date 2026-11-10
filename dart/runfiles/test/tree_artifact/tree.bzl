"""Test fixture: a rule whose only output is a tree artifact."""

def _tree_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run_shell(
        outputs = [out],
        command = "mkdir -p {d}/sub && echo top > {d}/top.txt && echo deep > {d}/sub/deep.txt".format(d = out.path),
    )
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

tree = rule(implementation = _tree_impl)
