"""A non-Dart rule that builds for a platform no Dart SDK is registered for."""

def _to_android(_settings, _attr):
    return {"//command_line_option:platforms": str(Label("//dart/tests/foreign_platform_fixture:android"))}

_android_transition = transition(
    implementation = _to_android,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _foreign_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".bundle")
    ctx.actions.write(out, "built for android\n")
    return [DefaultInfo(files = depset([out]))]

foreign_bundle = rule(
    implementation = _foreign_impl,
    cfg = _android_transition,
)
