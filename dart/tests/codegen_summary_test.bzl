"""Tests which analyzer-summary inputs a `dart_codegen` action takes.

Under `//dart:analyzer_summaries` a `generator_bin` shim reads its dependencies
from their summaries, and gets `--summary` and `--sdk-summary` for them. Only a
generator built on the builder shim takes those flags; a user's own generator
gets the unchanged command line. A closure with a Flutter embedder, or an SDK
newer than the pinned analyzer, gets none either.

The command line is an args object the tests cannot read, so each test reads
the action's inputs instead: the summaries are inputs exactly when they are
passed. The SDK summary is `analyzer_sdk_summary.sum`, and a dependency's is
`<name>.dart_analyzer_summary.sum`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart/private:dart_analyzer_summary.bzl", "dart_analyzer_summary")

_FLAG = str(Label("//dart:analyzer_summaries"))

def _has_input(actions, suffix):
    for action in actions:
        if action.mnemonic != "DartCodegen":
            continue
        for f in action.inputs.to_list():
            if f.short_path.endswith(suffix):
                return True
    return False

def _codegen_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        ctx.attr.expect_summaries,
        _has_input(actions, "analyzer_sdk_summary.sum"),
        "%s: whether the codegen action takes the SDK summary" % target.label,
    )
    asserts.equals(
        env,
        ctx.attr.expect_summaries,
        _has_input(actions, ".dart_analyzer_summary.sum"),
        "%s: whether the codegen action takes a dependency summary" % target.label,
    )
    files = target[DefaultInfo].files
    return analysistest.end(env) + [OutputGroupInfo(_validation = files, dart_analyze = files)]

def _codegen_inputs_test(flag):
    """Returns a codegen-inputs test whose `//dart:analyzer_summaries` is `flag`, or the default for None."""
    return analysistest.make(
        _codegen_inputs_test_impl,
        attrs = {"expect_summaries": attr.bool(mandatory = True)},
        config_settings = {} if flag == None else {_FLAG: flag},
        extra_target_under_test_aspects = [dart_analyzer_summary],
    )

# A shim generator with the flag at its default: it takes the summaries.
shim_codegen_inputs_test = _codegen_inputs_test(None)

# A shim generator with the flag off: nothing is passed, as before the flag.
shim_codegen_off_inputs_test = _codegen_inputs_test(False)

# A generator outside the shim, and a shim generator whose closure holds a
# Flutter embedder, both with the flag on: nothing is passed to either.
no_summaries_codegen_inputs_test = _codegen_inputs_test(True)
