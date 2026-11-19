"""Unit tests for the host and URI helpers of the pubspec reader's tool repository."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:toolchains_repo.bzl", "PLATFORMS", "host_platform", "host_toolchains_build_content", "unsupported_host_message")
load("//dart/pub:pubspec.bzl", "read_pubspec")
load("//dart/pub/private:pub_archive.bzl", "fetch_pub_archive")
load("//dart/pub/private/pubspec_reader:reader.bzl", "compile_reader", "file_uri", "reader_tool_repo")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

visibility("//dart/...")

def _file_uri_test_impl(ctx):
    env = unittest.begin(ctx)

    # A Windows path has an empty authority before its drive, not the drive as host.
    asserts.equals(env, "file:///C:/Users/me/_bazel/external/yaml", file_uri("C:\\Users\\me\\_bazel\\external\\yaml"))
    asserts.equals(env, "file:///C:/a/b", file_uri("C:/a/b"))
    asserts.equals(env, "file:///home/me/.cache/x", file_uri("/home/me/.cache/x"))

    # Characters a URI path cannot hold are escaped, not read as a fragment or query.
    asserts.equals(env, "file:///C:/Users/John%20Doe/a%23b%3Fc%25d", file_uri("C:\\Users\\John Doe\\a#b?c%d"))
    asserts.equals(env, "file:///tmp/%2Bx%2B", file_uri("/tmp/+x+"))
    return unittest.end(env)

def _host_platform_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "macos-arm64", host_platform(struct(name = "Mac OS X", arch = "aarch64")))
    asserts.equals(env, "macos-x64", host_platform(struct(name = "mac os x", arch = "x86_64")))
    asserts.equals(env, "linux-arm64", host_platform(struct(name = "linux", arch = "aarch64")))
    asserts.equals(env, "linux-x64", host_platform(struct(name = "linux", arch = "amd64")))
    asserts.equals(env, "windows-x64", host_platform(struct(name = "Windows 11", arch = "amd64")))
    asserts.equals(env, "windows-arm64", host_platform(struct(name = "Windows 11", arch = "aarch64")))

    # A machine with no SDK is that, not the nearest one that has one.
    for name, arch in [
        ("linux", "riscv64"),
        ("linux", "ppc64le"),
        ("linux", "s390x"),
        ("linux", "x86"),
        ("FreeBSD", "amd64"),
    ]:
        asserts.equals(env, None, host_platform(struct(name = name, arch = arch)), "%s %s" % (name, arch))
    return unittest.end(env)

_RISCV = struct(name = "Linux", arch = "riscv64", environ = {})

def _unsupported_host_test_impl(ctx):
    env = unittest.begin(ctx)
    message = unsupported_host_message(_RISCV)
    asserts.true(env, "Linux riscv64" in message and "linux-x64" in message, message)

    # A pubspec cannot be read there, and that fails no fetch.
    written = {}
    rctx = struct(
        name = "rules_dart++pub+x",
        original_name = "x",
        os = _RISCV,
        watch = lambda _: None,
        file = lambda path, content: written.update({path: content}),
    )
    read = read_pubspec(rctx, "x")
    asserts.equals(env, message, read.error)
    asserts.equals(env, None, read.pubspec)

    # Nor does a package archive, with no bsdtar to extract it.
    sha256 = "a" * 64
    asserts.false(env, fetch_pub_archive(rctx, "x", "1.0.0", sha256))
    asserts.equals(env, {"pubspec.yaml": "name: x\n"}, written)

    # A build needing Dart stops, saying why; with an SDK there is nothing to register.
    # Only on this machine: another execution platform may still have an SDK.
    content = host_toolchains_build_content(None, message, {}, {})
    asserts.true(env, json.encode(message) in content, content)
    asserts.true(env, 'toolchain_type = "@rules_dart//dart:toolchain_type"' in content, content)
    asserts.true(env, 'toolchain_type = "@rules_dart//dart:exec_tools_toolchain_type"' in content, content)
    asserts.true(env, "exec_compatible_with = HOST_CONSTRAINTS" in content, content)
    asserts.false(env, "toolchain(" in host_toolchains_build_content("linux-x64", None, {}, {}))
    return unittest.end(env)

def _reader_attempt(project_dart, project_exists, project_compiles, release_compiles):
    """Runs `compile_reader` with fakes; returns its result and what happened, in order."""
    events = []

    def path(label):
        events.append("path " + label)
        return struct(exists = project_exists if label == "project" else True, label = label)

    def execute(args, **_kwargs):
        dart = args[0].label
        events.append("compile " + dart)
        ok = project_compiles if dart == "project" else release_compiles
        return struct(return_code = 0 if ok else 1, stdout = "", stderr = dart + " says no")

    rctx = struct(
        attr = struct(project_dart = project_dart, project_sdk = "mine", dart = "release"),
        path = path,
        execute = execute,
    )
    result = compile_reader(rctx, "reader", lambda note: events.append("note " + note))
    return result, events

def _reader_compiles_with_the_project_sdk_test_impl(ctx):
    env = unittest.begin(ctx)
    result, events = _reader_attempt("project", True, True, True)
    asserts.equals(env, None, result.error)
    asserts.true(env, result.with_project_sdk)

    # The release is not touched, so it is not fetched.
    asserts.equals(env, ["path project", "compile project"], events)
    return unittest.end(env)

def _reader_says_why_it_needs_the_release_test_impl(ctx):
    env = unittest.begin(ctx)

    # The reason comes before the release is asked for: offline, that is where
    # the fetch fails, and it does not name the SDK the user chose.
    for project_dart, exists, why in [
        ("project", True, "project says no"),
        ("project", False, "no `dart`"),
        (None, True, "no build for this machine"),
    ]:
        result, events = _reader_attempt(project_dart, exists, False, True)
        asserts.equals(env, None, result.error)
        asserts.false(env, result.with_project_sdk)
        notes = [e for e in events if e.startswith("note ")]
        asserts.equals(env, 1, len(notes), str(events))
        asserts.true(env, why in notes[0] and '"mine"' in notes[0] and "`dart` release" in notes[0], notes[0])
        asserts.true(env, events.index(notes[0]) < events.index("path release"), str(events))

    # When that fails too, the failure gives both causes.
    result, _ = _reader_attempt("project", True, False, False)
    asserts.true(env, "project says no" in result.error and "release says no" in result.error, result.error)

    # A project that chose no SDK of its own has nothing to be told.
    rctx_events = []
    rctx = struct(
        attr = struct(project_dart = None, project_sdk = "", dart = "release"),
        path = lambda label: struct(exists = True, label = label),
        execute = lambda args, **_kwargs: struct(return_code = 0, stdout = "", stderr = ""),
    )
    asserts.equals(env, None, compile_reader(rctx, "reader", rctx_events.append).error)
    asserts.equals(env, [], rctx_events)
    return unittest.end(env)

_reader_project_sdk_test = unittest.make(_reader_compiles_with_the_project_sdk_test_impl)

_reader_release_test = unittest.make(_reader_says_why_it_needs_the_release_test_impl)

def _reader_repositories_collide_with_no_sdk_test_impl(ctx):
    env = unittest.begin(ctx)
    for platform in PLATFORMS:
        asserts.false(env, reader_tool_repo(platform).endswith("_" + platform), platform)
    return unittest.end(env)

_reader_repositories_test = unittest.make(_reader_repositories_collide_with_no_sdk_test_impl)

_unsupported_host_test = unittest.make(_unsupported_host_test_impl)

_file_uri_test = unittest.make(_file_uri_test_impl)
_host_platform_test = unittest.make(_host_platform_test_impl)

def reader_unit_test_suite(name):
    small_unittest_suite(name, _file_uri_test, _host_platform_test, _unsupported_host_test, _reader_repositories_test, _reader_project_sdk_test, _reader_release_test)
