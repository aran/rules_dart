"""Tests of `dart_package_cycle` (`package_cycle_fixture`)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartInfo")

def _refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

cycle_refused_test = analysistest.make(
    _refused_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)

def _cycle_packages_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartInfo]
    asserts.equals(
        env,
        ctx.attr.packages,
        ["%s %s %s" % (p.package_name, p.package_root, p.language_version or "-") for p in info.packages],
    )
    asserts.equals(
        env,
        sorted(ctx.attr.srcs),
        sorted([f.short_path for f in info.srcs]),
    )
    return analysistest.end(env)

cycle_packages_test = analysistest.make(
    _cycle_packages_test_impl,
    attrs = {
        "packages": attr.string_list(doc = "Each package the cycle contributes, as `name root language_version`, `-` for none."),
        "srcs": attr.string_list(doc = "The short paths of the cycle's own sources."),
    },
)

def _validation_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    groups = target[OutputGroupInfo]
    validation = groups._validation.to_list() if hasattr(groups, "_validation") else []
    asserts.equals(
        env,
        sorted(ctx.attr.basenames),
        sorted([f.basename for f in validation]),
    )
    return analysistest.end(env)

validation_test = analysistest.make(
    _validation_test_impl,
    attrs = {"basenames": attr.string_list(doc = "The basenames of the target's `_validation` files.")},
)
