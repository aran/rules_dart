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

def _root_options_action(env):
    """The action producing `<name>.proj/analysis_options.yaml`, or None."""
    for a in analysistest.target_actions(env):
        for out in a.outputs.to_list():
            if out.short_path.endswith(".proj/analysis_options.yaml"):
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
    # Presence alone proves nothing: `stage_root_options` declares that path in
    # every case and writes a comment-only stub when `options` is unset, so a
    # rule that silently dropped the user's file would still leave a file
    # there — and the check would run at stock defaults with nothing saying so.
    # Provenance is what separates the two cases, so provenance is what is
    # asserted: the staged file must derive from the fixture's `options.yaml`.
    # The stub is written from a string and has no inputs at all.
    root_options = _root_options_action(env)
    asserts.true(
        env,
        root_options != None,
        "nothing produces the staged project-root analysis_options.yaml",
    )
    if root_options == None:
        return analysistest.end(env)
    asserts.true(
        env,
        [
            f
            for f in root_options.inputs.to_list()
            if f.short_path.endswith("format_fixture/options.yaml")
        ] != [],
        "the staged project-root analysis_options.yaml does not come from " +
        "the options target's file, so the check runs at stock defaults: %s" %
        [f.short_path for f in root_options.inputs.to_list()],
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

def _format_language_version_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _format_action(env)
    asserts.true(env, action != None, "expected a DartFormat action")
    if action == None:
        return analysistest.end(env)

    # The version has to reach the formatter on the command line. It cannot be
    # inferred: the staged project holds no `package_config.json` entry for the
    # files this rule formats, so an inferred version is always the SDK's
    # newest — which is a different formatting *style* from the one the code
    # was written in whenever the package declares anything below 3.7.
    argv = action.argv
    asserts.true(
        env,
        "--language-version" in argv,
        "the language version is not passed to the formatter: %s" % argv,
    )
    if "--language-version" not in argv:
        return analysistest.end(env)
    asserts.equals(
        env,
        ctx.attr.expected_version,
        argv[argv.index("--language-version") + 1],
        "wrong language version passed to the formatter",
    )
    return analysistest.end(env)

format_language_version_test = analysistest.make(
    _format_language_version_test_impl,
    attrs = {"expected_version": attr.string(mandatory = True)},
)

def _format_bad_operand_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_error)
    return analysistest.end(env)

# `srcs` and `target` are two ways to name the same thing, and `target` already
# carries the language version that `language_version` would set — so each of
# these combinations has no meaning to pick, only meanings to guess between.
# The rule refuses rather than choosing; these pin the refusals, and the
# messages, because a build error a user cannot act on is barely better than
# the silent default this attribute exists to remove.
format_bad_operand_test = analysistest.make(
    _format_bad_operand_test_impl,
    attrs = {"expected_error": attr.string(mandatory = True)},
    expect_failure = True,
)
