"""Tests for the hermetic dart_format_test implementation.

The format check must run the compiled format_runner over a staged, declared
project directory — no shell, no runfiles, no mktemp. Running it over runfiles
is what made the rule read files no action had declared and let the formatter's
options walk-up escape into the execroot, so the shape of the action is the
thing worth pinning: an assertion here fails at analysis time, in every
execution mode at once, where the CI hermeticity matrix can only sample four.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _format_action(env):
    """The target's DartFormat action, or None."""
    for a in analysistest.target_actions(env):
        if a.mnemonic == "DartFormat":
            return a
    return None

def _format_is_hermetic_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _format_action(env)
    asserts.true(env, action != None, "expected a DartFormat action")
    if action == None:
        return analysistest.end(env)

    argv = action.argv
    asserts.true(
        env,
        "format_runner" in argv[0],
        "format must run the compiled format_runner, got: %s" % argv[0],
    )
    asserts.true(env, "--project" in argv, "missing --project in argv: %s" % argv)
    asserts.true(env, "--manifest" in argv, "missing --manifest in argv: %s" % argv)
    asserts.true(env, "--stamp" in argv, "missing --stamp in argv: %s" % argv)
    return analysistest.end(env)

format_hermetic_test = analysistest.make(_format_is_hermetic_test_impl)

def _format_stages_root_options_test_impl(ctx):
    env = analysistest.begin(ctx)

    # The fixture sets no `options`. That is the case the old rule left with
    # nothing at the project root, so the formatter's discovery walk climbed
    # past it — finding no configuration under a sandbox, and the workspace's
    # own file without one. The staged root file is what ends the walk, so its
    # presence is the whole assertion.
    action = _format_action(env)
    asserts.true(env, action != None, "expected a DartFormat action")
    if action == None:
        return analysistest.end(env)

    staged = [
        f.short_path
        for f in action.inputs.to_list()
        if f.short_path.endswith(".proj/analysis_options.yaml")
    ]
    asserts.true(
        env,
        staged != [],
        "no analysis_options.yaml is staged at the project root, so the " +
        "formatter's options walk-up escapes the staged project",
    )
    return analysistest.end(env)

format_stages_root_options_test = analysistest.make(
    _format_stages_root_options_test_impl,
)

def _format_options_closure_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _format_action(env)
    asserts.true(env, action != None, "expected a DartFormat action")
    if action == None:
        return analysistest.end(env)

    inputs = [f.short_path for f in action.inputs.to_list()]

    # The options file itself, staged where the formatter will discover it.
    asserts.true(
        env,
        [p for p in inputs if p.endswith(".proj/analysis_options.yaml")] != [],
        "the options file is not staged at the project root: %s" % inputs,
    )

    # And the closure its `include:` directives resolve against. An options
    # target's packages exist for exactly one reason — a `package:` URI is
    # resolved through the project's package_config like any import — so
    # staging the file without them would silently fall back to defaults.
    asserts.true(
        env,
        [p for p in inputs if ".extpkgs/" in p] != [],
        "the options target's packages are not staged, so an " +
        "`include: package:` URI could not resolve: %s" % inputs,
    )
    asserts.true(
        env,
        [p for p in inputs if p.endswith(".proj/.dart_tool/package_config.json")] != [],
        "no package_config.json is staged to resolve `package:` includes: %s" % inputs,
    )
    return analysistest.end(env)

format_options_closure_test = analysistest.make(
    _format_options_closure_test_impl,
)

def _format_external_src_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "external repositories")
    return analysistest.end(env)

# External sources are refused rather than staged: `stage_dart_project` keeps an
# external file only when a known external package claims it, so a loose one
# would be dropped from the tree and the manifest would name a path that does
# not exist. The rule's own `fail` is the only thing standing between that and
# a confusing build error, so it is pinned here.
format_external_src_test = analysistest.make(
    _format_external_src_test_impl,
    expect_failure = True,
)
