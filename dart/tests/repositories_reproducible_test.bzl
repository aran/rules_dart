"""Unit tests that the toolchain repository rules are marked reproducible.

Bazel shares a repository marked reproducible across output bases through the
repository contents cache, so the Dart SDK is downloaded and extracted once per
machine. The mark is only true if the repository's contents depend on its
attributes alone. Each implementation runs here against a context that offers
the downloads and file writes the rule makes and nothing that reads the host
(`os`, `getenv`, `execute`, `watch`, `which`): a rule that started reading the
host would fail here, rather than share one machine's repository with another.

The SDK is an `http_archive`, which Bazel marks reproducible when it is given a
`sha256` and nothing else that varies, so that test checks the attributes
rather than running an implementation.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart:repositories.bzl", "dart_cross_tools_attrs", "dart_sdk_repo_attrs")
load("//dart/private:sdk_fetch.bzl", "dart_fetched_files_impl")
load("//dart/private:toolchains_repo.bzl", "CROSS_TARGETS", "PLATFORMS", "cross_pair", "toolchains_repo_impl")
load("//dart/private:versions.bzl", "CROSS_TOOL_VERSIONS", "TOOL_VERSIONS")
load("//dart/pub/private/pubspec_reader:reader.bzl", "pubspec_reader_tool_impl")
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
        attrs = dart_sdk_repo_attrs(version, platform)

        # `http_archive` returns `reproducible = True` for a pinned digest,
        # and Bazel's repository contents cache keys the repository by its
        # attributes: any other would be a copy of the SDK per value.
        asserts.equals(env, ["build_file_content", "sha256", "strip_prefix", "url"], sorted(attrs.keys()), "%s SDK repository" % platform)
        asserts.equals(env, TOOL_VERSIONS[version][platform], attrs["sha256"], "%s SDK repository" % platform)
        asserts.equals(env, 64, len(attrs["sha256"]), "%s SDK repository" % platform)
        asserts.true(env, attrs["url"].startswith("https://"), "%s SDK repository" % platform)

        # Those attributes hold only the release: toolchains, which name other
        # repositories and change with rules_dart, would store the SDK again
        # with each change.
        build = attrs["build_file_content"]
        asserts.false(env, "dart_toolchain" in build, build)
        asserts.false(env, "_cross_" in build, build)
    return unittest.end(env)

def _cross_tools_are_reproducible_test_impl(ctx):
    env = unittest.begin(ctx)
    version = CROSS_TOOL_VERSIONS.keys()[0]
    for exec_platform, targets in CROSS_TARGETS.items():
        for target_platform in targets:
            metadata = dart_fetched_files_impl(_context(**dart_cross_tools_attrs(
                version,
                exec_platform,
                target_platform,
                "0" * 64,
                "1" * 64,
            )))
            asserts.true(
                env,
                metadata and metadata.reproducible,
                "%s to %s cross tools" % (exec_platform, target_platform),
            )
    return unittest.end(env)

def _toolchains_are_reproducible_test_impl(ctx):
    env = unittest.begin(ctx)
    parts = {"version": TOOL_VERSIONS.keys()[0], "hosts": {}, "cross": {}, "tools": {}}
    parts["hosts"] = {platform: {"error": "none here"} for platform in PLATFORMS.keys()}
    parts["cross"] = {cross_pair(p, t): {"error": "none here"} for p, targets in CROSS_TARGETS.items() for t in targets}
    parts["tools"] = {"kernel": {"error": "none here"}, "analyzer": {"error": "none here"}}
    metadata = toolchains_repo_impl(_context(sdks = {"dart": json.encode(parts)}, default_sdk = "dart", unavailable = {}))
    asserts.true(env, metadata and metadata.reproducible, "toolchains repository")
    return unittest.end(env)

def _reader_context(os_name, arch, written, deleted, platform = "linux-x64", project_sdk = ""):
    """A `repository_ctx` for the pubspec reader of `platform`, on the given host."""

    def write(path, content = "", **_):
        written[path] = content

    return struct(
        attr = struct(
            platform = platform,
            dart = "dart",
            project_dart = "fork_dart" if project_sdk else None,
            project_sdk = project_sdk,
            packages = {"yaml_pubspec": "yaml"},
            src = "src",
        ),
        delete = deleted.append,
        execute = lambda *_args, **_kwargs: struct(return_code = 0, stdout = "", stderr = ""),
        file = write,
        original_name = "pubspec_reader-" + platform,
        os = struct(name = os_name, arch = arch),
        path = lambda _: struct(dirname = struct(realpath = "/output_base/external/yaml"), exists = True),
        read = lambda _: "",
        repo_metadata = lambda reproducible: struct(reproducible = reproducible),
    )

def _a_stand_in_reader_is_not_shared_test_impl(ctx):
    env = unittest.begin(ctx)

    # The real reader has this rule and these attributes: a cache keyed by them
    # must never give it to a machine in place of the stand-in's, or back.
    for os_name, arch in [("mac os x", "aarch64"), ("windows 11", "amd64"), ("freebsd", "amd64"), ("linux", "riscv64")]:
        written = {}
        metadata = pubspec_reader_tool_impl(_reader_context(os_name, arch, written, []))
        asserts.false(env, metadata.reproducible, "reader for linux-x64 on %s %s" % (os_name, arch))
        asserts.true(env, "dart_sdk_error" in written["BUILD.bazel"], written["BUILD.bazel"])
    return unittest.end(env)

def _the_real_reader_is_shared_test_impl(ctx):
    env = unittest.begin(ctx)
    written = {}
    deleted = []
    metadata = pubspec_reader_tool_impl(_reader_context("linux", "amd64", written, deleted))
    asserts.true(env, metadata.reproducible, "the reader of the release, on its own platform")
    asserts.equals(env, 'exports_files(["pubspec_reader"])\n', written["BUILD.bazel"])

    # What would tie the shared copy to this output base is gone.
    asserts.equals(env, ["package_config.json"], deleted)

    # The project's SDK may be this machine's own build.
    metadata = pubspec_reader_tool_impl(_reader_context("linux", "amd64", {}, [], project_sdk = "fork"))
    asserts.false(env, metadata.reproducible, "the reader of a project's own SDK")
    return unittest.end(env)

_t0_test = unittest.make(_sdk_is_reproducible_test_impl)
_t1_test = unittest.make(_cross_tools_are_reproducible_test_impl)
_t2_test = unittest.make(_toolchains_are_reproducible_test_impl)
_t3_test = unittest.make(_a_stand_in_reader_is_not_shared_test_impl)
_t4_test = unittest.make(_the_real_reader_is_shared_test_impl)

def repositories_reproducible_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
