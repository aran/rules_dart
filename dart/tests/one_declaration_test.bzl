"""Tests of a package's one `dart_package_metadata` (`one_declaration_fixture`)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartInfo")

def _refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

declaration_refused_test = analysistest.make(
    _refused_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)

def _declared_root_test_impl(ctx):
    env = analysistest.begin(ctx)
    packages = analysistest.target_under_test(env)[DartInfo].transitive_packages.to_list()
    asserts.equals(env, [ctx.attr.root], [p.package_root for p in packages])
    return analysistest.end(env)

declared_root_test = analysistest.make(
    _declared_root_test_impl,
    attrs = {"root": attr.string(mandatory = True)},
)
