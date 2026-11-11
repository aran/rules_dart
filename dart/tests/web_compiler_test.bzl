"""Tests for the runtime constraint: what the web binaries build for, and what resets it.

A target's configuration shows in its outputs' root: one built with no web
compiler writes under the same `bin` directory as the test itself, and one
configured for a compiler writes under another.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("//dart:utils.bzl", "web_platform_config_settings")

# buildifier: disable=bzl-visibility
load("//dart/private:runtime.bzl", "web_platform_transition", "web_platforms_transition")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:build_content.bzl", "make_dart_library_build_content")
load(":small_suite.bzl", "small_unittest_suite")

_VARIANT = "dart/tests/web_compiler_fixture/%s/lib/variant.dart"

def _variant_test_impl(ctx):
    env = analysistest.begin(ctx)
    srcs = [
        f.short_path
        for f in analysistest.target_under_test(env)[DartAnalyzableInfo].dart_info.transitive_srcs.to_list()
    ]
    for variant in ["js", "wasm", "native"]:
        asserts.equals(
            env,
            variant == ctx.attr.expected,
            _VARIANT % variant in srcs,
            "the %s variant %s; sources: %s" % (
                variant,
                "should be the one picked" if variant == ctx.attr.expected else "should not be reached",
                srcs,
            ),
        )
    return analysistest.end(env)

# The binary's `deps` see its compiler, so the `select()` beneath picks its
# variant, and only that one.
variant_test = analysistest.make(
    _variant_test_impl,
    attrs = {"expected": attr.string(mandatory = True)},
)

def _roots(info):
    roots = {}
    for f in info.transitive_srcs.to_list():
        if not f.is_source:
            roots[f.basename] = f.root.path
    for f in info.transitive_code_asset_files.to_list():
        roots["code asset"] = f.root.path
    return roots

_RootsInfo = provider(
    doc = "Output roots of a library's generated files, reached plainly and in another configuration.",
    fields = ["plain", "other"],
)

def _roots_under_js_impl(ctx):
    return [_RootsInfo(
        plain = _roots(ctx.attr.library[DartInfo]),
        other = _roots(ctx.attr.library_under_js[0][DartInfo]),
    )]

# Reaches one library twice: as a plain build does, and as `dart_js_binary`
# does. Comparing the two sides inside one analysis test keeps both in the same
# test configuration.
roots_under_js = rule(
    implementation = _roots_under_js_impl,
    attrs = {
        "library": attr.label(providers = [DartInfo]),
        "library_under_js": attr.label(providers = [DartInfo], cfg = web_platform_transition),
        "platform": attr.label(default = "//dart/platforms:js"),
    },
)

def _resets_test_impl(ctx):
    env = analysistest.begin(ctx)
    roots = analysistest.target_under_test(env)[_RootsInfo]
    for name in ["independent.dart", "model.g.dart", "code asset"]:
        asserts.equals(
            env,
            roots.plain.get(name),
            roots.other.get(name),
            "%s should be built once, with no web compiler, whether a web binary reaches it or not" % name,
        )

    # The control: an unmarked first-party library is configured for the
    # compiler, so the roots above are not equal by accident.
    asserts.true(
        env,
        roots.other.get("forked.dart") not in [None, roots.plain.get("forked.dart")],
        "forked.dart should be configured for js, got roots %s" % roots,
    )
    return analysistest.end(env)

# Pub-style libraries marked `runtime_independent`, codegen and code assets
# fall back to the configuration with no web compiler, so each is built once.
resets_test = analysistest.make(_resets_test_impl)

_TRACK = str(Label("//dart:track_creation_locations"))

def _track_impl(_settings, _attr):
    return {_TRACK: True}

_track = transition(implementation = _track_impl, inputs = [], outputs = [_TRACK])

def _roots_tracked_impl(ctx):
    return [_RootsInfo(
        plain = _roots(ctx.attr.library[DartInfo]),
        other = _roots(ctx.attr.library_tracked[0][DartInfo]),
    )]

# Reaches one library twice, with `track_creation_locations` off and on, as a
# build of an app and of a Flutter test beside it does.
roots_tracked = rule(
    implementation = _roots_tracked_impl,
    attrs = {
        "library": attr.label(providers = [DartInfo]),
        "library_tracked": attr.label(providers = [DartInfo], cfg = _track),
    },
)

def _tracking_resets_test_impl(ctx):
    env = analysistest.begin(ctx)
    roots = analysistest.target_under_test(env)[_RootsInfo]
    for name in ["model.g.dart", "code asset"]:
        asserts.equals(
            env,
            roots.plain.get(name),
            roots.other.get(name),
            "%s cannot depend on track_creation_locations, so should be built once" % name,
        )

    # Libraries are compiled to kernel modules in their own configuration, so
    # they keep the flag, pub-style independent ones too: a module compiled
    # without the transform would not link with one compiled with it.
    for name in ["independent.dart", "forked.dart"]:
        asserts.true(
            env,
            roots.other.get(name) not in [None, roots.plain.get(name)],
            "%s should be configured with track_creation_locations on, got roots %s" % (name, roots.other),
        )
    return analysistest.end(env)

# Codegen and code assets turn `track_creation_locations` off; libraries keep it.
tracking_resets_test = analysistest.make(_tracking_resets_test_impl)

_JS_SETTINGS = web_platform_config_settings(Label("//dart/platforms:js"))

def _as_dict_impl(_settings, _attr):
    return _JS_SETTINGS

# The dict, applied from the test's own configuration.
_as_dict = transition(
    implementation = _as_dict_impl,
    inputs = [],
    outputs = list(_JS_SETTINGS.keys()),
)

_RESET = ["independent.dart", "model.g.dart", "code asset"]

def _config_settings_test_impl(ctx):
    env = analysistest.begin(ctx)
    plain = _roots(ctx.attr.plain[DartInfo])
    by_dict = _roots(ctx.attr.by_dict[0][DartInfo])
    by_transition = _roots(ctx.attr.by_transition[0][DartInfo])
    asserts.equals(
        env,
        by_transition,
        by_dict,
        "the dict should configure the library and everything beneath it as a web binary's deps are",
    )
    for name in _RESET:
        asserts.equals(env, plain.get(name), by_dict.get(name), "%s should be reset to the plain build's configuration" % name)

    # Bazel configures everything under a test's `config_settings` apart from
    # the build outside it ("evaluating for analysis test"), so there the
    # comparison is within: the resets leave js, all for one configuration.
    under_test = _roots(analysistest.target_under_test(env)[DartInfo])
    reset = {under_test.get(name): None for name in _RESET}
    asserts.equals(env, 1, len(reset), "the resets should land in one configuration: %s" % under_test)
    asserts.true(
        env,
        under_test.get("forked.dart") not in [None] + reset.keys(),
        "forked.dart should be configured for js, and the resets not: %s" % under_test,
    )
    return analysistest.end(env)

# `web_platform_config_settings` configures a target as `web_platform_transition`
# does, both as the test's `config_settings` and applied as a transition.
config_settings_test = analysistest.make(
    _config_settings_test_impl,
    attrs = {
        "by_dict": attr.label(providers = [DartInfo], cfg = _as_dict),
        "by_transition": attr.label(providers = [DartInfo], cfg = web_platform_transition),
        "plain": attr.label(providers = [DartInfo]),
        "platform": attr.label(default = "//dart/platforms:js"),
    },
    config_settings = _JS_SETTINGS,
)

_INCOMPATIBLE = str(Label("@platforms//:incompatible"))

_ConstraintsInfo = provider(doc = "Constraint values a select resolved to.", fields = ["labels"])

def _constraints_impl(ctx):
    return [_ConstraintsInfo(labels = [str(c.label) for c in ctx.attr.constraints])]

# Holds a `target_compatible_with` value as an ordinary attribute, so a test
# can see what it resolves to on a platform. A target that is itself
# incompatible would make every target reaching it incompatible, the test too.
constraints = rule(
    implementation = _constraints_impl,
    attrs = {"constraints": attr.label_list(providers = [platform_common.ConstraintValueInfo])},
)

def _web_only_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.true(
        env,
        _INCOMPATIBLE in ctx.attr.plain[_ConstraintsInfo].labels,
        "web-only code should be incompatible with the host, a VM platform",
    )
    asserts.equals(env, sorted([str(p.label) for p in ctx.attr.web_platforms]), sorted(ctx.split_attr.web.keys()))
    for platform, value in ctx.split_attr.web.items():
        asserts.equals(
            env,
            [],
            value[_ConstraintsInfo].labels,
            "web-only code should be compatible with %s" % platform,
        )
    return analysistest.end(env)

# The `target_compatible_with` docs/ARCHITECTURE.md gives web-only code
# ("Per-compiler code") holds on no VM platform and on each web platform.
web_only_test = analysistest.make(
    _web_only_test_impl,
    attrs = {
        "plain": attr.label(providers = [_ConstraintsInfo]),
        "web": attr.label(providers = [_ConstraintsInfo], cfg = web_platforms_transition),
        "web_platforms": attr.label_list(),
    },
)

def _pub_libraries_are_independent_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in ["glyphs", "test"]:
        content = make_dart_library_build_content(name, [], "3.13")
        asserts.true(
            env,
            "    runtime_independent = True,\n" in content,
            "a pub package's dart_library must be marked compiler-independent: %s" % content,
        )
    return unittest.end(env)

# Every pub spoke, and rules_flutter's, which use the same generator, is built
# once whatever the web compiler.
_pub_libraries_are_independent_test = unittest.make(_pub_libraries_are_independent_test_impl)

def web_compiler_test_suite(name):
    small_unittest_suite(name, _pub_libraries_are_independent_test)

def _wrong_platform_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

# A web binary given a platform without its compiler's constraint says which
# constraint the platform carries and which it lacks.
wrong_platform_test = analysistest.make(
    _wrong_platform_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)
