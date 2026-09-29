"""Tests for the package an executable may state (`executable_package.bzl`).

Two kinds. `package_config_probe_test` reads the `package_config.json` an
executable writes — the compile's for a VM target, the staged one for a web
target — and its `DartAnalyzableInfo`, which analysis and the format check
read. `executable_package_refused_test` pins each contradiction the rules
refuse, by the message that names it.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartAnalyzableInfo")
load("//dart/private:common.bzl", "own_package_record")

def _package_config_probe_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    content = None
    for action in analysistest.target_actions(env):
        for out in action.outputs.to_list():
            if out.basename.endswith("package_config.json"):
                content = action.content
    asserts.true(env, content != None, "expected a package_config.json write action")
    if content == None:
        return analysistest.end(env)
    for expected in ctx.attr.expected:
        asserts.true(
            env,
            expected in content,
            "expected `%s` in the package_config:\n%s" % (expected, content),
        )
    for unexpected in ctx.attr.unexpected:
        asserts.false(
            env,
            unexpected in content,
            "did not expect `%s` in the package_config:\n%s" % (unexpected, content),
        )

    record = own_package_record(target[DartAnalyzableInfo].dart_info)
    if ctx.attr.expected_package_name:
        asserts.true(env, record != None, "expected the executable to carry its own package record")
        if record != None:
            asserts.equals(env, ctx.attr.expected_package_name, record.package_name)
            asserts.equals(env, ctx.attr.expected_language_version, record.language_version)
    else:
        asserts.equals(env, None, record, "an executable stating no package must carry none")
    return analysistest.end(env)

# What an executable's generated `package_config.json` says, and which package
# record its `DartAnalyzableInfo` carries (none when `expected_package_name` is
# empty).
package_config_probe_test = analysistest.make(
    _package_config_probe_test_impl,
    attrs = {
        "expected": attr.string_list(),
        "unexpected": attr.string_list(),
        "expected_package_name": attr.string(),
        "expected_language_version": attr.string(),
    },
)

def _executable_package_refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

# An executable whose stated package contradicts its deps, and the error that
# says so.
executable_package_refused_test = analysistest.make(
    _executable_package_refused_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)
