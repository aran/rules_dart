"""Tests that the settings describing the app being built stop at the exec configuration.

A build-time tool (codegen, a Flutter tool) is reached through `cfg = "exec"`,
by rules_dart's rules or anyone else's. Its compile must not take the app's
`-D` declarations, and changing them must not reconfigure, and so rebuild,
every tool. `scope = "target"` on each such setting has Bazel reset it on every
exec transition.

`:holder` depends on `:tool` through a plain `cfg = "exec"`. The probe reaches
it twice: as configured for the test, and through a transition that changes
every app setting. An aspect reads the tool's `DartKernel` action on each side.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_KERNEL = "DartKernel"

# Each app setting, changed from its default.
_APP_SETTINGS = {
    str(Label("//dart:extra_dart_defines")): ["LEAK=1"],
    str(Label("//dart/private:module_defines")): ["MODULE_LEAK=1"],
    str(Label("//dart:track_creation_locations")): True,
    str(Label("//dart:kernel_list")): False,
    str(Label("//dart:runner_snapshot")): True,
    str(Label("//dart:analysis_worker")): False,
    str(Label("//dart:analysis_config")): str(Label("//dart/tests/exec_scope_fixture:other_analysis_config")),
}

def _app_settings_impl(_settings, _attr):
    return _APP_SETTINGS

_app_settings = transition(
    implementation = _app_settings_impl,
    inputs = [],
    outputs = _APP_SETTINGS.keys(),
)

_ToolCompileInfo = provider(
    doc = "The `DartKernel` action of the exec tool beneath a target.",
    fields = {
        "argv": "The action's argv, or None.",
        "outputs": "The paths of its outputs.",
    },
)

_EMPTY = _ToolCompileInfo(argv = None, outputs = [])

def _from(dep):
    if type(dep) == "list":
        dep = dep[0]
    return dep[_ToolCompileInfo] if _ToolCompileInfo in dep else _EMPTY

_ProbeInfo = provider(
    doc = "The exec tool's compile, from the plain and the changed configuration.",
    fields = ["plain", "changed"],
)

def _tool_compile_aspect_impl(target, ctx):
    if hasattr(ctx.rule.attr, "changed"):
        return [_ProbeInfo(plain = _from(ctx.rule.attr.plain), changed = _from(ctx.rule.attr.changed))]
    for action in target.actions:
        if action.mnemonic == _KERNEL:
            return [_ToolCompileInfo(argv = action.argv, outputs = [f.path for f in action.outputs.to_list()])]
    if hasattr(ctx.rule.attr, "tool"):
        return [_from(ctx.rule.attr.tool)]
    return []

_tool_compile_aspect = aspect(
    implementation = _tool_compile_aspect_impl,
    attr_aspects = ["tool", "plain", "changed"],
)

def _holder_impl(_ctx):
    return []

exec_scope_holder = rule(
    implementation = _holder_impl,
    attrs = {"tool": attr.label(cfg = "exec", executable = True, mandatory = True)},
)

def _probe_impl(_ctx):
    return []

exec_scope_probe = rule(
    implementation = _probe_impl,
    attrs = {
        "changed": attr.label(cfg = _app_settings, mandatory = True),
        "plain": attr.label(mandatory = True),
    },
)

def _exec_scope_test_impl(ctx):
    env = analysistest.begin(ctx)
    probe = analysistest.target_under_test(env)[_ProbeInfo]
    if probe.plain.argv == None or probe.changed.argv == None:
        asserts.true(env, False, "expected a %s action for the exec tool on both sides" % _KERNEL)
        return analysistest.end(env)
    for argv in [probe.plain.argv, probe.changed.argv]:
        for arg in argv:
            asserts.false(env, "LEAK=1" in arg, "an app define reached the exec tool's compile: %s" % arg)
    asserts.equals(env, probe.plain.argv, probe.changed.argv, "the exec tool's compile changed with the app settings")
    asserts.equals(env, probe.plain.outputs, probe.changed.outputs, "the app settings changed the exec configuration")
    return analysistest.end(env)

exec_scope_test = analysistest.make(
    _exec_scope_test_impl,
    extra_target_under_test_aspects = [_tool_compile_aspect],
)
