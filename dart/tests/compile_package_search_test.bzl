"""`dart compile`'s search for a package config ends in the target's own directory.

`dart compile exe|aot-snapshot` walks up from its input to the nearest
`.dart_tool/package_config.json`, and where it finds none but a
`pubspec.yaml`, runs `pub get` there and that package's build hooks. Without
a sandbox the walk reaches the workspace's pubspec through the execroot. The
compile's input sits in a directory of the target's own with an empty package
config above it, an input of the action, so the walk stops there.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _compile_package_search_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartCompile"]
    asserts.equals(env, 1, len(actions), "one DartCompile action")
    if len(actions) != 1:
        return analysistest.end(env)
    action = actions[0]
    compiled = action.argv[-1]
    inputs = [f.path for f in action.inputs.to_list()]
    marker = "/%s.compile/" % ctx.attr.target_under_test.label.name
    asserts.true(env, marker in compiled, "the compiled input %s is not under %s" % (compiled, marker))
    if marker in compiled:
        root = compiled[:compiled.index(marker) + len(marker)]
        for name in ["package_config.json", "package_graph.json"]:
            path = root + ".dart_tool/" + name
            asserts.true(env, path in inputs, "%s is not an input of %s" % (path, compiled))
    return analysistest.end(env)

compile_package_search_test = analysistest.make(_compile_package_search_test_impl)
