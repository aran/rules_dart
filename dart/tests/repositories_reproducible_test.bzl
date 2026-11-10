"""Unit tests that the toolchain repository rules are marked reproducible.

Bazel shares a repository marked reproducible across output bases through the
repository contents cache, so the Dart SDK is downloaded and extracted once per
machine. The mark is only true if the repository's contents depend on its
attributes alone. Each implementation runs here against a context that offers
the downloads and file writes the rule makes and nothing that reads the host
(`os`, `getenv`, `execute`, `watch`, `which`): a rule that started reading the
host would fail here, rather than share one machine's repository with another.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart:repositories.bzl", "dart_cross_tools_impl", "dart_sdk_repo_impl")
load("//dart/private:toolchains_repo.bzl", "CROSS_TARGETS", "PLATFORMS", "toolchains_repo_impl")
load("//dart/private:versions.bzl", "CROSS_TOOL_VERSIONS", "TOOL_VERSIONS")
load(":small_suite.bzl", "small_unittest_suite")

def _context(**attrs):
    """A `repository_ctx` with only the calls the toolchain rules make."""
    return struct(
        attr = struct(**attrs),
        download = lambda **_: None,
        download_and_extract = lambda **_: None,
        file = lambda *_args, **_kwargs: None,
        repo_metadata = lambda reproducible: struct(reproducible = reproducible),
    )

def _sdk_is_reproducible_test_impl(ctx):
    env = unittest.begin(ctx)
    version = TOOL_VERSIONS.keys()[0]
    for platform in PLATFORMS.keys():
        metadata = dart_sdk_repo_impl(_context(
            dart_version = version,
            platform = platform,
            user_repository_name = "dart",
        ))
        asserts.true(env, metadata and metadata.reproducible, "%s SDK repository" % platform)
    return unittest.end(env)

def _cross_tools_are_reproducible_test_impl(ctx):
    env = unittest.begin(ctx)
    version = CROSS_TOOL_VERSIONS.keys()[0]
    for exec_platform, targets in CROSS_TARGETS.items():
        for target_platform in targets:
            metadata = dart_cross_tools_impl(_context(
                dart_version = version,
                exec_platform = exec_platform,
                target_platform = target_platform,
            ))
            asserts.true(
                env,
                metadata and metadata.reproducible,
                "%s to %s cross tools" % (exec_platform, target_platform),
            )
    return unittest.end(env)

def _toolchains_are_reproducible_test_impl(ctx):
    env = unittest.begin(ctx)
    metadata = toolchains_repo_impl(_context(user_repository_name = "dart", dart_version = TOOL_VERSIONS.keys()[0]))
    asserts.true(env, metadata and metadata.reproducible, "toolchains repository")
    return unittest.end(env)

_t0_test = unittest.make(_sdk_is_reproducible_test_impl)
_t1_test = unittest.make(_cross_tools_are_reproducible_test_impl)
_t2_test = unittest.make(_toolchains_are_reproducible_test_impl)

def repositories_reproducible_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test)
