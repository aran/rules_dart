"""Tests that a program reaching no code asset configures no C/C++ target.

A target that builds C or C++ resolves a C/C++ toolchain, which on a machine
without a compiler fails the build: only a build that reaches a code asset may
need one. The aspect walks every attribute, the toolchains and tools of rules
built in the exec configuration included.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

_CcTargetsInfo = provider(
    doc = "Labels of the C/C++ targets a target reaches.",
    fields = {"labels": "depset[Label]"},
)

def _collect_impl(target, ctx):
    reached = []
    for attr in dir(ctx.rule.attr):
        value = getattr(ctx.rule.attr, attr)
        for dep in value if type(value) == "list" else [value]:
            if type(dep) == "Target" and _CcTargetsInfo in dep:
                reached.append(dep[_CcTargetsInfo].labels)
    own = [target.label] if CcInfo in target else []
    return [_CcTargetsInfo(labels = depset(own, transitive = reached))]

_collect = aspect(
    implementation = _collect_impl,
    attr_aspects = ["*"],
)

def _impl(ctx):
    env = analysistest.begin(ctx)
    labels = ctx.attr.target_under_test[_CcTargetsInfo].labels.to_list()
    asserts.equals(env, [], labels, "C/C++ targets a pure-Dart program reaches")
    return analysistest.end(env)

no_cc_test = analysistest.make(
    _impl,
    extra_target_under_test_aspects = [_collect],
)
