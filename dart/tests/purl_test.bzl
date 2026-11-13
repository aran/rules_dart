"""Unit tests for the package identity (purl) fetched repositories state.

Each repository rules_dart fetches from a registry says what it holds through
Bazel's supply-chain metadata: a `package_metadata` target with a purl, which
its `REPO.bazel` attaches to every target in it. These test the purls and the
files the repository rules write. That the targets of a real repository carry
them is the e2e workspaces' to show (and, for the native code rules_dart
builds in place of a package's build hook, `package_metadata_check`):
`e2e/examples/pub/lock` (hosted, `pub.package()` and the SDK) and
`e2e/examples/pub/git` (git).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart:repositories.bzl", "dart_cross_tools_impl", "dart_sdk_repo_impl")
load("//dart/private:versions.bzl", "CROSS_TOOL_VERSIONS", "TOOL_VERSIONS")

# buildifier: disable=bzl-visibility
load("//dart/pub/private:build_content.bzl", "make_dart_library_build_content", "make_pub_member_build_content", "pub_git_purl", "pub_hosted_purl", "pub_package_identity")
load(":small_suite.bzl", "small_unittest_suite")

_SHA = "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5"
_COMMIT = "0123456789abcdef0123456789abcdef01234567"

def _hosted_test_impl(ctx):
    env = unittest.begin(ctx)
    want = "pkg:pub/path@1.9.1?checksum=sha256:" + _SHA

    # pub.dev, by either of its names, is what a pub purl means unqualified.
    for base_url in ["https://pub.dev", "https://pub.dev/", "https://pub.dartlang.org"]:
        asserts.equals(env, want, pub_hosted_purl("path", "1.9.1", _SHA, base_url), base_url)
    asserts.equals(env, want, pub_hosted_purl("path", "1.9.1", _SHA))
    asserts.equals(
        env,
        "pkg:pub/path@1.9.1?checksum=sha256:" + _SHA + "&repository_url=https:%2F%2Fpub.example.com%2Fapi",
        pub_hosted_purl("path", "1.9.1", _SHA, "https://pub.example.com/api/"),
    )

    # A pre-release's `+` and `-` are kept in the version, encoded as purl encodes them.
    asserts.equals(
        env,
        "pkg:pub/path@2.0.0-dev.1%2B3?checksum=sha256:" + _SHA,
        pub_hosted_purl("path", "2.0.0-dev.1+3", _SHA),
    )
    return unittest.end(env)

def _git_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "pkg:pub/git_root@1.0.0?vcs_url=git%2Bhttps:%2F%2Fexample.com%2Froot.git%40" + _COMMIT,
        pub_git_purl("git_root", "1.0.0", "https://example.com/root.git", _COMMIT),
    )

    # A package in a subdirectory names it, so two packages of one commit differ.
    asserts.equals(
        env,
        "pkg:pub/git_sub@1.0.0?vcs_url=git%2Bremote.git%40" + _COMMIT + "%23pkgs%2Fsub",
        pub_git_purl("git_sub", "1.0.0", "remote.git", _COMMIT, "pkgs/sub"),
    )
    return unittest.end(env)

def _spoke_files_test_impl(ctx):
    env = unittest.begin(ctx)
    purl = pub_hosted_purl("p", "1.0.0", _SHA)
    target = '''
package_metadata(
    name = "package-metadata",
    purl = "%s",
    visibility = ["//visibility:public"],
)
''' % purl
    for content in [
        make_pub_member_build_content("p", "3.0", "1.0.0", purl = purl),
        make_dart_library_build_content("p", [], "3.0", purl = purl),
        make_dart_library_build_content("test", [], "3.0", purl = purl),
    ]:
        asserts.true(env, target in content, content)

        # Every load comes before the first target.
        asserts.true(env, content.rfind("\nload(") < content.find("\npackage_metadata("), content)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package-metadata"])\n', pub_package_identity(purl).repo_file)
    asserts.equals(env, struct(loads = "", target = "", repo_file = ""), pub_package_identity(""))

    # A package of the user's own (a path package) states its own, if any.
    for content in [
        make_pub_member_build_content("p", "3.0", "1.0.0"),
        make_dart_library_build_content("p", [], "3.0"),
    ]:
        asserts.true(env, "\npackage_metadata(" not in content and "package_metadata.bzl" not in content, content)
    return unittest.end(env)

def _recording_context(**attrs):
    files = {}
    return files, struct(
        attr = struct(**attrs),
        download = lambda **_: None,
        download_and_extract = lambda **_: None,
        file = lambda path, content = "", **_kwargs: files.update({path: content}),
        repo_metadata = lambda reproducible: struct(reproducible = reproducible),
    )

def _sdk_test_impl(ctx):
    env = unittest.begin(ctx)
    version = TOOL_VERSIONS.keys()[0]
    files, rctx = _recording_context(dart_version = version, platform = "linux-x64", user_repository_name = "dart")
    dart_sdk_repo_impl(rctx)
    sha256 = TOOL_VERSIONS[version]["linux-x64"]
    want = ("pkg:generic/dart-sdk@{v}?checksum=sha256:{sha}&download_url=https:%2F%2Fstorage.googleapis.com" +
            "%2Fdart-archive%2Fchannels%2Fstable%2Frelease%2F{v}%2Fsdk%2Fdartsdk-linux-x64-release.zip").format(v = version, sha = sha256)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package_metadata"])\n', files.get("REPO.bazel"))
    build = files.get("BUILD.bazel", "")
    asserts.true(env, 'purl = "%s"' % want in build, build)
    asserts.true(env, build.rfind("\nload(") < build.find("\ndart_sdk_files("), build)

    # The cross-compilation files are of the same release.
    version = CROSS_TOOL_VERSIONS.keys()[0]
    files, rctx = _recording_context(dart_version = version, exec_platform = "linux-x64", target_platform = "linux-arm64")
    dart_cross_tools_impl(rctx)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package_metadata"])\n', files.get("REPO.bazel"))
    build = files.get("BUILD.bazel", "")
    asserts.true(env, 'purl = "pkg:generic/dart-sdk@%s?checksum=sha256:' % version in build, build)
    return unittest.end(env)

# --- native code rules_dart builds in place of a package's build hook ---

_MetadataLabelsInfo = provider(doc = "The `package_metadata` each target of a closure names.", fields = ["by_target"])

_EDGES = ["deps", "file"]

def _metadata_labels_impl(target, ctx):
    by_target = {str(target.label): [str(m.label) for m in getattr(ctx.rule.attr, "package_metadata", [])]}
    for name in _EDGES:
        value = getattr(ctx.rule.attr, name, None)
        for dep in value if type(value) == "list" else [value]:
            if type(dep) == "Target" and _MetadataLabelsInfo in dep:
                by_target.update(dep[_MetadataLabelsInfo].by_target)
    return [_MetadataLabelsInfo(by_target = by_target)]

_metadata_labels = aspect(implementation = _metadata_labels_impl, attr_aspects = _EDGES)

def _package_metadata_check_impl(ctx):
    by_target = {}
    for dep in ctx.attr.deps:
        by_target.update(dep[_MetadataLabelsInfo].by_target)
    got = {target: by_target.get(str(Label(target))) for target in ctx.attr.want}
    want = {target: [str(Label(m)) for m in labels.split(" ")] for target, labels in ctx.attr.want.items()}
    if got != want:
        fail("package_metadata by target:\n  got  %s\n  want %s" % (got, want))
    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

package_metadata_check = rule(
    implementation = _package_metadata_check_impl,
    doc = "Fails analysis unless each target of the closure names exactly the `package_metadata` stated. Build it to test.",
    attrs = {
        "deps": attr.label_list(aspects = [_metadata_labels], mandatory = True),
        "want": attr.string_dict(
            doc = "Target in the deps' closure -> the labels of its `package_metadata`, space-separated.",
            mandatory = True,
        ),
    },
)

_hosted_test = unittest.make(_hosted_test_impl)
_git_test = unittest.make(_git_test_impl)
_spoke_files_test = unittest.make(_spoke_files_test_impl)
_sdk_test = unittest.make(_sdk_test_impl)

def purl_test_suite(name):
    """Registers the purl unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    small_unittest_suite(name, _hosted_test, _git_test, _spoke_files_test, _sdk_test)
