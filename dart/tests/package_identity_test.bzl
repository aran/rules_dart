"""Tests for `dart_package` and the identity agreement it makes checkable.

Analysis-time throughout. `codegen_identity_error` reads a provider off a
target in `srcs` and `resolve_package_identity` reads a rule's attributes, so
neither can be exercised by calling it with plain structs the way
`package_agreement_error` can — both need real targets, which is what
`analysistest` supplies.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "own_package_record")

def _identity_probe_impl(ctx):
    """Asserts a `dart_package` reached the library's own `DartPackageInfo`."""
    info = ctx.attr.target[DartInfo]
    pkg = own_package_record(info)
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

def _codegen_package_name_conflict_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "collects them into package")
    return analysistest.end(env)

codegen_package_name_conflict_test = analysistest.make(
    _codegen_package_name_conflict_impl,
    expect_failure = True,
)

def _language_version_conflict_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "ran its generator under Dart language version")
    return analysistest.end(env)

language_version_conflict_test = analysistest.make(
    _language_version_conflict_impl,
    expect_failure = True,
)

def _package_and_inline_conflict_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "sets `package` and also")
    return analysistest.end(env)

package_and_inline_conflict_test = analysistest.make(
    _package_and_inline_conflict_impl,
    expect_failure = True,
)
