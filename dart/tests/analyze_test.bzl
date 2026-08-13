"""Tests for the hermetic dart_analyze_test implementation.

The analyze action must run the compiled analyze_runner over a staged, declared
project directory — no shell, no mktemp.

The rest of this file covers the other half of what the rule accepts: an
executable. A `dart_binary`/`dart_test` entrypoint belongs to no package's
`lib/`, so it reaches the rule through `DartAnalyzableInfo` rather than
`DartInfo`, and the cases below pin both directions of that — that the
entrypoint really is staged for analysis, and that the provider carrying it is
still not something `deps` will accept.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")

# The fixture's entrypoint and its dependency, by the suffix of their
# `short_path`. Named here rather than passed in: these tests exist for one
# fixture, and a path an assertion cannot find is the failure they report.
_ENTRYPOINT = "/analyzable_fixture/main.dart"
_DEP_PACKAGE = "analyzable_dep"

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

def _analyzable_provider_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    # The whole point of the wrapper: analyzable, and still not a dependency.
    # `deps` everywhere in this rule set and downstream gates on `DartInfo`, so
    # an executable handing one out would make `dart_library(deps = [":bin"])`
    # legal — the rule-level guard on that is `binary_not_a_dep_test` below.
    asserts.true(
        env,
        DartAnalyzableInfo in target,
        "a dart_binary must provide DartAnalyzableInfo",
    )
    asserts.false(
        env,
        DartInfo in target,
        "a dart_binary must NOT provide DartInfo — that is what `deps` requires",
    )
    if DartAnalyzableInfo not in target:
        return analysistest.end(env)

    analyzable = target[DartAnalyzableInfo]

    # The entrypoint, which no `DartInfo` can carry: it is under no package's
    # `lib/`, so no `DartPackageInfo` names it and no `package:` URI reaches it.
    srcs = sorted([f.short_path for f in analyzable.srcs.to_list()])
    asserts.true(
        env,
        [p for p in srcs if p.endswith(_ENTRYPOINT)] != [],
        "the entrypoint is missing from DartAnalyzableInfo.srcs: %s" % srcs,
    )

    # And the closure around it, which one is: staging the entrypoint alone
    # would leave its imports unresolvable.
    names = sorted([
        p.package_name
        for p in analyzable.dart_info.transitive_packages.to_list()
    ])
    asserts.true(
        env,
        _DEP_PACKAGE in names,
        "the dependency's package record is missing from the nested DartInfo: %s" % names,
    )

    return analysistest.end(env)

analyzable_provider_test = analysistest.make(_analyzable_provider_test_impl)

def _stages_entrypoint_test_impl(ctx):
    env = analysistest.begin(ctx)

    # Scanned across every action rather than the DartAnalyze one: the analyzer
    # is handed a project directory, so the entrypoint reaches it as a member of
    # the `src` tree artifact that `copy_to_directory` assembles, and only that
    # action lists it by name.
    staged = []
    for a in analysistest.target_actions(env):
        staged.extend([
            f.short_path
            for f in a.inputs.to_list()
            if f.short_path.endswith(_ENTRYPOINT)
        ])
    asserts.true(
        env,
        staged != [],
        "no action of the analyze target consumes the entrypoint — it was " +
        "never staged, so `dart analyze` never saw it",
    )
    return analysistest.end(env)

stages_entrypoint_test = analysistest.make(_stages_entrypoint_test_impl)

def _binary_not_a_dep_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "mandatory providers")
    return analysistest.end(env)

# The guard on the central tension. `dart_binary` is analyzable *and* an invalid
# dep, and nothing but Bazel's own provider constraint enforces the second half
# — there is no negative provider constraint to say "not this one". If an
# executable ever starts returning `DartInfo`, this is what goes red.
binary_not_a_dep_test = analysistest.make(
    _binary_not_a_dep_test_impl,
    expect_failure = True,
)

def _both_operands_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "not both")
    return analysistest.end(env)

def _no_operand_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "missing `target`")
    return analysistest.end(env)

# Neither `target` nor `lib` can be `mandatory` while the other exists, so the
# error Bazel used to raise for a missing `lib` is now the rule's to raise.
both_operands_test = analysistest.make(
    _both_operands_test_impl,
    expect_failure = True,
)
no_operand_test = analysistest.make(
    _no_operand_test_impl,
    expect_failure = True,
)
