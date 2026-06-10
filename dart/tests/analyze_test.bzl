"""Tests for the hermetic dart_analyze_test implementation.

The analyze action must run the compiled analyze_runner over a staged,
declared project directory — no shell, no mktemp.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _analyze_is_hermetic_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = None
    for a in analysistest.target_actions(env):
        if a.mnemonic == "DartAnalyze":
            action = a
    asserts.true(env, action != None, "expected a DartAnalyze action")
    argv = action.argv
    asserts.true(
        env,
        "analyze_runner" in argv[0],
        "analyze must run the compiled analyze_runner, got: %s" % argv[0],
    )
    asserts.true(env, "--project" in argv, "missing --project in argv: %s" % argv)
    asserts.true(env, "--fatal-infos" in argv, "missing --fatal-infos in argv: %s" % argv)
    asserts.true(env, "--stamp" in argv, "missing --stamp in argv: %s" % argv)
    return analysistest.end(env)

analyze_hermetic_test = analysistest.make(_analyze_is_hermetic_test_impl)
