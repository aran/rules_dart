"""Analysis tests: every Dart action can share its result across configurations.

Under `--experimental_output_paths=strip` an action that declares
`supports-path-mapping` sees every configuration's output directory as
`bazel-out/cfg/bin`, so two configurations that build the same thing build it
once. A path that reaches the action as a string, or inside a file it reads,
still names one configuration: it splits the cache, and inside the action's
sandbox it does not exist. These look for one in the target's own actions; the
aspects' actions (modules of dependencies, import checks, analysis) build the
same way and are covered by a build's execution log, not here.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _unmapped(text):
    """The configuration directories `text` names other than the mapped one."""
    return [part.partition("/")[0] for part in text.split("bazel-out/")[1:] if not part.startswith("cfg/")]

def _path_mapping_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)

    # An action that does not declare `supports-path-mapping` shows its File
    # arguments unmapped, so the arguments are the whole check.
    dart = [a for a in actions if a.mnemonic.startswith("Dart")]
    asserts.true(env, dart, "no Dart actions to check")
    read = {}
    for action in dart:
        for f in action.inputs.to_list():
            read[f] = True
        for arg in action.argv:
            asserts.equals(env, [], _unmapped(arg), "%s passes `%s`" % (action.mnemonic, arg))
    for action in actions:
        if action.mnemonic == "FileWrite" and action.outputs.to_list()[0] in read:
            asserts.equals(env, [], _unmapped(action.content), "%s names an output directory:\n%s" % (action.outputs.to_list()[0].short_path, action.content))
    return analysistest.end(env)

path_mapping_test = analysistest.make(
    _path_mapping_test_impl,
    config_settings = {
        "//command_line_option:experimental_output_paths": "strip",
    },
)
