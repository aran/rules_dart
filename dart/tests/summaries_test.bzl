"""Where analysis against summaries finds a target's summaries: its providers.

A library's rule declares its summary through `dart_info()`, and `DartInfo`
carries it with every summary the library depends on, so an analysis reads
them off whatever provider it stages, however the target came by it.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("//dart/private:dart_analyze_aspect.bzl", "dart_analyze")

def _basenames(files):
    return [f.short_path.rpartition("/")[2] for f in files.to_list()]

def _reaches_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    summaries = _basenames(target[DartAnalyzableInfo].dart_info.summaries.deps)
    asserts.equals(env, ["lib.dart_summary.sum"], summaries)
    return analysistest.end(env)

# The outer target's libraries are reachable only through the providers of a
# rule that knows nothing of Dart.
summaries_reach_test = analysistest.make(_reaches_impl)

def _summarized_against_embedder_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    summaries = target[DartInfo].summaries
    asserts.true(env, summaries.sdk != None, "no SDK summary reaches %s" % target.label)
    asserts.equals(env, ctx.attr.engine.label, summaries.sdk_owner)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartSummarize"]
    asserts.equals(env, 1, len(actions))
    asserts.true(
        env,
        summaries.sdk.path in actions[0].argv,
        "%s is summarized against %s, not the SDK summary of its analysis-only engine %s" % (target.label, actions[0].argv, summaries.sdk.path),
    )
    return analysistest.end(env)

# A library whose analysis-only dependency adds `dart:fake` to the SDK is
# summarized against that SDK, and hands it on.
summarized_against_embedder_test = analysistest.make(
    _summarized_against_embedder_impl,
    attrs = {"engine": attr.label()},
)

def _refused_impl(ctx):
    env = analysistest.begin(ctx)
    for part in ctx.attr.messages:
        asserts.expect_failure(env, part)
    return analysistest.end(env)

# Analysis against summaries refuses a target whose summaries cannot be built,
# naming what is missing and the flag that turns summaries off.
summaries_refused_test = analysistest.make(
    _refused_impl,
    expect_failure = True,
    attrs = {"messages": attr.string_list()},
    extra_target_under_test_aspects = [dart_analyze],
)
