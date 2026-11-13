"""Analysis tests over the web compiler setting, from outside rules_dart.

A target's configuration shows in its outputs' root, so a generated file built
once has the same root under every compiler and in a plain build.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "web_platforms_transition")
load(":defs.bzl", "NativeModuleInfo", "WEB_PLATFORMS_ATTR")

_RootsInfo = provider(
    doc = "Generated file short path to output root, per compiler (`none` for a plain build).",
    fields = ["by_compiler"],
)

def _roots(target):
    roots = {}
    for f in target[DartInfo].transitive_srcs.to_list():
        if not f.is_source:
            roots[f.short_path] = f.root.path
    if NativeModuleInfo in target:
        for f in target[NativeModuleInfo].modules.to_list():
            roots[f.short_path] = f.root.path
    return roots

def _compiler_roots_impl(ctx):
    by_compiler = {"none": _roots(ctx.attr.plain)}
    for platform, target in ctx.split_attr.lib.items():
        by_compiler[Label(platform).name] = _roots(target)
    return [_RootsInfo(by_compiler = by_compiler)]

# Reaches one library under each compiler and in a plain build.
compiler_roots = rule(
    implementation = _compiler_roots_impl,
    attrs = {
        "lib": attr.label(providers = [DartInfo], cfg = web_platforms_transition),
        "plain": attr.label(providers = [DartInfo]),
    } | WEB_PLATFORMS_ATTR,
)

def _shared_test_impl(ctx):
    env = analysistest.begin(ctx)
    by_compiler = analysistest.target_under_test(env)[_RootsInfo].by_compiler
    plain = by_compiler["none"]

    # Where a plain build writes: the control's root, which nothing resets.
    baseline = plain[ctx.attr.forked[0]]
    for path in ctx.attr.shared:
        for compiler, roots in by_compiler.items():
            if path not in roots:
                continue
            asserts.equals(
                env,
                baseline,
                roots[path],
                "%s should be built once, with no web compiler, but %s builds it elsewhere" % (path, compiler),
            )
    for path in ctx.attr.forked:
        asserts.true(
            env,
            by_compiler["js"].get(path) not in [None, plain.get(path)],
            "%s should be configured for js, which makes the check above meaningful" % path,
        )
    return analysistest.end(env)

# The generated files in `shared` are built in the plain build's configuration
# under every compiler; those in `forked`, the control, are not.
shared_test = analysistest.make(
    _shared_test_impl,
    attrs = {
        "shared": attr.string_list(),
        "forked": attr.string_list(),
    },
)

def _variant_test_impl(ctx):
    env = analysistest.begin(ctx)
    srcs = [
        f.short_path
        for f in analysistest.target_under_test(env)[DartAnalyzableInfo].dart_info.transitive_srcs.to_list()
    ]
    asserts.true(env, ctx.attr.picked in srcs, "%s should be reached: %s" % (ctx.attr.picked, srcs))
    asserts.false(env, ctx.attr.not_picked in srcs, "%s should not be reached: %s" % (ctx.attr.not_picked, srcs))
    return analysistest.end(env)

# A binary reaches only its own compiler's variant.
variant_test = analysistest.make(
    _variant_test_impl,
    attrs = {
        "picked": attr.string(),
        "not_picked": attr.string(),
    },
)
