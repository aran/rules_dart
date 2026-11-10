"""Tests for `dart_package_metadata` and the identity agreement it makes checkable.

Analysis-time throughout. `codegen_identity_error` reads a provider off a
target in `srcs`, so it needs real targets, which is what `analysistest`
supplies.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "own_packages")

def _identity_probe_impl(ctx):
    """Asserts a `dart_package_metadata` reached the library's own `DartPackageInfo`."""
    info = ctx.attr.target[DartInfo]
    pkg = (own_packages(info) or [None])[0]
    if pkg == None:
        fail("%s: %s contributes no package record." % (ctx.label, ctx.attr.target.label))
    if pkg.package_name != ctx.attr.expected_package_name:
        fail("%s: expected package_name %r, got %r" % (
            ctx.label,
            ctx.attr.expected_package_name,
            pkg.package_name,
        ))
    if pkg.language_version != ctx.attr.expected_language_version:
        fail("%s: expected language_version %r, got %r" % (
            ctx.label,
            ctx.attr.expected_language_version,
            pkg.language_version,
        ))
    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

identity_probe = rule(
    implementation = _identity_probe_impl,
    attrs = {
        "target": attr.label(providers = [DartInfo], mandatory = True),
        "expected_package_name": attr.string(mandatory = True),
        "expected_language_version": attr.string(mandatory = True),
    },
    doc = "Fails unless `target`'s own package record carries the expected identity.",
)

def _codegen_identity_conflict_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

# A library collecting generated sources for another package than its own, and
# the error that names both.
codegen_identity_conflict_test = analysistest.make(
    _codegen_identity_conflict_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)
