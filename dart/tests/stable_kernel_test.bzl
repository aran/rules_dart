"""Analysis coverage for the deterministic VM frontend pipeline."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart/private:common.bzl", "stable_kernel_uri")
load("//dart/private:dart_compile.bzl", "split_dart_compile_flags")
load(":small_suite.bzl", "small_unittest_suite")

_DART_COMPILE = "DartCompile"
_DART_KERNEL = "DartKernel"
_SCHEME = "org-dartlang-bazel"

def _action(env, mnemonic):
    for action in analysistest.target_actions(env):
        if action.mnemonic == mnemonic:
            return action
    return None

def _flag_value(argv, flag):
    for i in range(len(argv) - 1):
        if argv[i] == flag:
            return argv[i + 1]
    return None

def _stable_kernel_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    kernel = _action(env, _DART_KERNEL)
    if kernel == None:
        asserts.true(env, False, "expected a %s action" % _DART_KERNEL)
        return analysistest.end(env)

    argv = kernel.argv
    asserts.equals(env, ".", _flag_value(argv, "--filesystem-root"))
    asserts.equals(env, _SCHEME, _flag_value(argv, "--filesystem-scheme"))
    entrypoint = argv[-1]
    asserts.true(
        env,
        entrypoint.startswith(_SCHEME + ":///"),
        "entrypoint is not stable: %s" % entrypoint,
    )
    asserts.true(
        env,
        entrypoint.endswith(ctx.attr.entrypoint_suffix),
        "unexpected entrypoint URI: %s" % entrypoint,
    )

    packages = _flag_value(argv, "--packages")
    if ctx.attr.expect_packages:
        asserts.true(
            env,
            packages != None and packages.startswith(_SCHEME + ":///"),
            "package config is not a stable URI: %s" % packages,
        )
    else:
        # Even an empty config is passed explicitly, preventing compiler
        # discovery from walking outside the declared action inputs.
        asserts.true(
            env,
            packages != None and packages.startswith(_SCHEME + ":///"),
            "empty package config is not a stable URI: %s" % packages,
        )

    asserts.equals(
        env,
        ctx.attr.expect_native_assets,
        "--native-assets" in argv,
        "native-assets routing",
    )
    for flag in ctx.attr.frontend_flags:
        asserts.true(env, flag in argv, "%s missing from frontend argv %s" % (flag, argv))

    backend = _action(env, _DART_COMPILE)
    if ctx.attr.compile_mode:
        if backend == None:
            asserts.true(env, False, "expected a %s action" % _DART_COMPILE)
            return analysistest.end(env)
        asserts.true(
            env,
            ctx.attr.compile_mode in backend.argv,
            "compile mode %s missing from %s" % (ctx.attr.compile_mode, backend.argv),
        )
        for flag in ctx.attr.backend_flags:
            asserts.true(env, flag in backend.argv, "%s missing from backend argv %s" % (flag, backend.argv))
        for flag in ctx.attr.frontend_only_flags:
            asserts.false(env, flag in backend.argv, "%s leaked into backend argv %s" % (flag, backend.argv))
    else:
        asserts.equals(env, None, backend, "dart_test should expose its stable kernel directly")
    return analysistest.end(env)

stable_kernel_action_test = analysistest.make(
    _stable_kernel_action_test_impl,
    attrs = {
        "backend_flags": attr.string_list(),
        "compile_mode": attr.string(),
        "entrypoint_suffix": attr.string(default = "main.dart"),
        "expect_native_assets": attr.bool(),
        "expect_packages": attr.bool(),
        "frontend_flags": attr.string_list(),
        "frontend_only_flags": attr.string_list(),
    },
)

def _reserved_mapping_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rules_dart reserves the execroot filesystem mapping")
    return analysistest.end(env)

reserved_mapping_test = analysistest.make(
    _reserved_mapping_test_impl,
    expect_failure = True,
)

def _stable_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "org-dartlang-bazel:///pkg/main.dart", stable_kernel_uri("pkg/main.dart"))
    asserts.equals(env, "org-dartlang-bazel:///pkg/main.dart", stable_kernel_uri("/pkg\\main.dart"))
    return unittest.end(env)

def _flag_routing_test_impl(ctx):
    env = unittest.begin(ctx)
    routed = split_dart_compile_flags([
        "--enable-experiment=test-experiment",
        "--no-embed-sources",
        "--verbosity=warning",
        "--enable-asserts",
        "--extra-gen-snapshot-options=--optimization_level=3",
    ])
    asserts.equals(
        env,
        [
            "--enable-experiment=test-experiment",
            "--no-embed-sources",
            "--verbosity=warning",
            "--enable-asserts",
        ],
        routed.frontend,
    )
    asserts.equals(
        env,
        [
            "--verbosity=warning",
            "--enable-asserts",
            "--extra-gen-snapshot-options=--optimization_level=3",
        ],
        routed.backend,
    )
    return unittest.end(env)

_stable_uri_test = unittest.make(_stable_uri_test_impl)
_flag_routing_test = unittest.make(_flag_routing_test_impl)

def stable_kernel_test_suite(name):
    """Registers pure helper tests for the stable frontend.

    Args:
      name: Aggregating test suite name.
    """
    small_unittest_suite(name, _stable_uri_test, _flag_routing_test)
