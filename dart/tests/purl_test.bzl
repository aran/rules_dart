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
load("//dart:repositories.bzl", "dart_cross_tools_attrs", "dart_sdk_repo_attrs")

# buildifier: disable=bzl-visibility
load("//dart/private:package_info.bzl", "directory_identity", "fetched_identity_text", "local_git_identity", "purl_identity")
load("//dart/private:sdk_fetch.bzl", "dart_fetched_files_impl")
load("//dart/private:versions.bzl", "CROSS_TOOL_VERSIONS", "TOOL_VERSIONS")
load("//dart/pub:pub_files_root.bzl", "write_pub_files_root")
load("//dart/pub:pub_lock_package.bzl", "pub_files_fetched")
load("//dart/pub/private:build_content.bzl", "make_dart_library_build_content", "make_package_metadata_content", "make_pub_member_build_content", "pub_git_purl", "pub_git_source", "pub_hosted_purl", "pub_hosted_source", "pub_package_identity", "pub_path_source")
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

    # A package in a subdirectory names it, so two packages of one commit
    # differ, and every spelling of one directory names it alike.
    want = "pkg:pub/git_sub@1.0.0?vcs_url=git%2Bhttps:%2F%2Fexample.com%2Fremote.git%40" + _COMMIT + "%23pkgs%2Fsub"
    for path in ["pkgs/sub", "./pkgs/sub", "pkgs/sub/", "pkgs/x/../sub", "pkgs\\sub"]:
        asserts.equals(env, want, pub_git_purl("git_sub", "1.0.0", "https://example.com/remote.git", _COMMIT, path), path)
    root = pub_git_purl("git_root", "1.0.0", "https://example.com/root.git", _COMMIT)
    for path in ["./", "", "pkgs/.."]:
        asserts.equals(env, root, pub_git_purl("git_root", "1.0.0", "https://example.com/root.git", _COMMIT, path), path)

    # A url naming its repository on its own is identified by its purl.
    asserts.equals(env, struct(identity = purl_identity(want), purl = want), pub_git_source("git_sub", "1.0.0", "https://example.com/remote.git", _COMMIT, "pkgs/sub"))
    asserts.equals(env, struct(identity = purl_identity(root), purl = root), pub_git_source("git_root", "1.0.0", "https://example.com/root.git", _COMMIT, lock = Label("//app:pubspec.lock")))
    return unittest.end(env)

def _relative_git_identity_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = Label("//app:pubspec.lock")

    def identity(url, path = ".", at = lock):
        return pub_git_source("p", "1.0.0", url, _COMMIT, path, at).identity

    # A relative url names a repository in the lock's repository, found from
    # the lock as a path package's directory is, which no purl can name.
    want = local_git_identity("", "shared", _COMMIT, "")
    asserts.equals(env, want, identity("../shared"))
    asserts.equals(env, "git+@@//shared@" + _COMMIT, fetched_identity_text(want))
    in_package = local_git_identity("", "shared", _COMMIT, "pkgs/p")
    asserts.equals(env, in_package, identity("../shared", "./pkgs/p/"))
    asserts.equals(env, "git+@@//shared@" + _COMMIT + "#pkgs/p", fetched_identity_text(in_package))

    # However the locks spell it, one repository is one identity.
    asserts.equals(env, want, identity("shared", at = Label("//:pubspec.lock")))
    asserts.equals(env, want, identity("./../shared/"))

    # One text relative to two locks names two repositories.
    asserts.true(env, want != identity("../shared", at = Label("//app/x:pubspec.lock")))
    asserts.true(env, want != identity("../shared", at = Label("@bazel_skylib//app:pubspec.lock")))

    # Nor is it a path package of that directory, or another commit of it.
    asserts.true(env, want != pub_path_source(lock, "../shared").identity)
    asserts.true(env, want != local_git_identity("", "shared", "f" * 40, ""))

    # Its purl is the lock's url as written, so an SBOM lists the package,
    # by a location that says it is a path from the lock's checkout.
    source = pub_git_source("p", "1.0.0", "../shared", _COMMIT, "pkgs/p", lock)
    purl = pub_git_purl("p", "1.0.0", "../shared", _COMMIT, "pkgs/p")
    asserts.equals(env, purl, source.purl)
    asserts.equals(env, "pkg:pub/p@1.0.0?vcs_url=git%2B..%2Fshared%40" + _COMMIT + "%23pkgs%2Fp", purl)
    stated = pub_package_identity(source)
    asserts.true(env, 'purl = "%s"' % purl in stated.target, stated.target)
    asserts.true(env, '"fetched_local_git_package_metadata")' in stated.loads, stated.loads)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package-metadata"])\n', stated.repo_file)
    for content in [
        make_pub_member_build_content("p", "3.0", "1.0.0", source = source),
        make_dart_library_build_content("p", [], "3.0", source = source),
    ]:
        asserts.true(env, 'purl = "%s"' % purl in content, content)
        for line in ['repository = "",', 'directory = "shared",', 'commit = "%s",' % _COMMIT, 'package_path = "pkgs/p",']:
            asserts.true(env, line in content, content)
        asserts.true(env, "\nfetched_local_git_package_metadata(\n" in content, content)

    # Outside the lock's repository it has no identity, and is still listed,
    # declared as a package no fetcher states.
    outside = pub_git_source("p", "1.0.0", "../../shared", _COMMIT, lock = lock)
    asserts.equals(env, struct(identity = None, purl = pub_git_purl("p", "1.0.0", "../../shared", _COMMIT)), outside)
    stated = pub_package_identity(outside)
    asserts.true(env, "\npackage_metadata(" in stated.target, stated.target)
    asserts.true(env, '"dart_package_metadata")' in stated.loads, stated.loads)
    asserts.true(env, "fetched_" not in stated.loads, stated.loads)
    asserts.true(env, make_package_metadata_content("p", "3.0", source = outside).startswith("dart_package_metadata("))
    return unittest.end(env)

def _spoke_files_test_impl(ctx):
    env = unittest.begin(ctx)
    source = pub_hosted_source("p", "1.0.0", _SHA)
    purl = pub_hosted_purl("p", "1.0.0", _SHA)
    asserts.equals(env, struct(identity = purl_identity(purl), purl = purl), source)
    target = '''
package_metadata(
    name = "package-metadata",
    purl = "%s",
    visibility = ["//visibility:public"],
)
''' % purl
    for content in [
        make_pub_member_build_content("p", "3.0", "1.0.0", source = source),
        make_dart_library_build_content("p", [], "3.0", source = source),
        make_dart_library_build_content("test", [], "3.0", source = source),
    ]:
        asserts.true(env, target in content, content)

        # Every load comes before the first target.
        asserts.true(env, content.rfind("\nload(") < content.find("\npackage_metadata("), content)

        # A fetched package is declared by `fetched_package_metadata` alone.
        asserts.true(env, '"dart_package_metadata"' not in content, content)

        # The purl is the package's fetched identity too.
        asserts.true(env, "\nfetched_package_metadata(\n" in content, content)
        asserts.equals(env, 2, content.count('purl = "%s",' % purl), content)
        asserts.true(env, content.rfind("\nload(") < content.find("\nfetched_package_metadata("), content)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package-metadata"])\n', pub_package_identity(source).repo_file)

    # A package no fetcher states states its own supply-chain metadata, if any.
    asserts.equals(
        env,
        struct(loads = 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")\n', target = "", repo_file = ""),
        pub_package_identity(None),
    )
    for content in [
        make_pub_member_build_content("p", "3.0", "1.0.0"),
        make_dart_library_build_content("p", [], "3.0"),
    ]:
        asserts.true(env, "\npackage_metadata(" not in content and "package_metadata.bzl" not in content, content)
        asserts.true(env, "\ndart_package_metadata(" in content and "repository =" not in content, content)
        asserts.true(env, '"dart_package_metadata")' in content, content)

    # A path package built from its pubspec states its directory as its
    # fetched identity, and no purl: its files are its repository's own.
    path = pub_path_source(Label("//app:pubspec.lock"), "../shared/p")
    asserts.equals(env, struct(identity = directory_identity("", "shared/p"), purl = ""), path)
    asserts.equals(env, struct(loads = 'load("@rules_dart//dart/private:fetched_package_metadata.bzl", "fetched_path_package_metadata")\n', target = "", repo_file = ""), pub_package_identity(path))
    for content in [
        make_pub_member_build_content("p", "3.0", "1.0.0", source = path),
        make_dart_library_build_content("p", [], "3.0", source = path),
    ]:
        asserts.true(env, "\npackage_metadata(" not in content and "//rules:package_metadata.bzl" not in content, content)
        asserts.true(env, "\nfetched_path_package_metadata(\n" in content, content)
        asserts.true(env, 'repository = "",' in content and 'directory = "shared/p",' in content, content)
        asserts.true(env, '"dart_package_metadata"' not in content, content)
        asserts.true(env, content.rfind("\nload(") < content.find("\nfetched_path_package_metadata("), content)
    return unittest.end(env)

def _path_identity_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = Label("//app:pubspec.lock")

    def identity(path, at = lock):
        return pub_path_source(at, path).identity

    # The directory from the root of the lock's repository, by the
    # repository's canonical name: the main repository's is empty.
    want = directory_identity("", "shared/p")
    asserts.equals(env, want, identity("../shared/p"))
    asserts.equals(env, "@@//shared/p", fetched_identity_text(want))

    # However the lock spells it, one directory is one identity.
    for path in ["../shared/p/", "./../shared/p", "../shared/./p", "../shared/q/../p", "..\\shared\\p", "../shared//p"]:
        asserts.equals(env, want, identity(path), path)
    asserts.equals(env, want, identity("shared/p", Label("//:pubspec.lock")))
    asserts.equals(env, want, identity("../../p", Label("//shared/x/y:pubspec.lock")))

    # A lock whose name has a directory sits in it, not in its package.
    asserts.equals(env, directory_identity("", "pkg/local"), identity("../local", Label("//pkg:sub/pubspec.lock")))
    asserts.equals(env, directory_identity("", "sub/local"), identity("local", Label("//:sub/pubspec.lock")))

    # The lock's own directory, and the repository's root.
    asserts.equals(env, directory_identity("", "app"), identity("."))
    asserts.equals(env, directory_identity("", ""), identity(".."))
    asserts.equals(env, "@@//", fetched_identity_text(identity("..")))

    # Different directories differ, a repository's included.
    asserts.true(env, identity("../shared/p") != identity("../other/p"))
    asserts.true(env, identity("p") != identity("../p"))
    other_repo = Label("@bazel_skylib//:pubspec.lock")
    asserts.equals(env, directory_identity(other_repo.repo_name, "shared/p"), identity("shared/p", other_repo))
    asserts.true(env, other_repo.repo_name != "")
    asserts.true(env, want != identity("shared/p", other_repo))

    # A directory no label names, absolute or leaving the lock's repository,
    # has no source a lock alone can state: only its machine can place it.
    for path in ["/home/me/p", "C:\\p", "c:/p", "../../p", "../../../app/p"]:
        asserts.equals(env, None, pub_path_source(lock, path), path)

    # Placed, it is named by where it is, and reads as that.
    asserts.equals(env, "/home/me/p", fetched_identity_text(directory_identity("", "/home/me/p")))
    asserts.equals(env, "C:/me/p", fetched_identity_text(directory_identity("", "C:/me/p")))
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
    attrs = dart_sdk_repo_attrs(version, "linux-x64")
    sha256 = TOOL_VERSIONS[version]["linux-x64"]
    want = ("pkg:generic/dart-sdk@{v}?checksum=sha256:{sha}&download_url=https:%2F%2Fstorage.googleapis.com" +
            "%2Fdart-archive%2Fchannels%2Fstable%2Frelease%2F{v}%2Fsdk%2Fdartsdk-linux-x64-release.zip").format(v = version, sha = sha256)
    asserts.equals(env, sha256, attrs["sha256"])
    build = attrs["build_file_content"]
    asserts.true(env, 'purl = "%s"' % want in build, build)

    # An `http_archive` writes no `REPO.bazel`, so the SDK's one BUILD file
    # attaches the metadata to its package, after its loads.
    asserts.true(env, 'package(default_package_metadata = ["//:package_metadata"])' in build, build)
    asserts.true(env, build.rfind("\nload(") < build.find("\npackage("), build)
    asserts.true(env, build.find("\npackage(") < build.find("\ndart_sdk_files("), build)
    asserts.true(env, build.rfind("\nload(") < build.find("\ndart_sdk_files("), build)

    # The cross-compilation files are of the same release.
    version = CROSS_TOOL_VERSIONS.keys()[0]
    files, rctx = _recording_context(**dart_cross_tools_attrs(version, "linux-x64", "linux-arm64", "0" * 64, "1" * 64))
    dart_fetched_files_impl(rctx)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package_metadata"])\n', files.get("REPO.bazel"))
    build = files.get("BUILD.bazel", "")
    asserts.true(env, 'purl = "pkg:generic/dart-sdk@%s?checksum=sha256:' % version in build, build)
    return unittest.end(env)

def _files_record_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = Label("//app:pubspec.lock")
    hosted = {"source": "hosted", "package_name": "p", "version": "1.0.0", "sha256": _SHA, "base_url": "https://pub.dev"}
    git = {"source": "git", "package_name": "p", "version": "1.0.0", "url": "https://example.com/p.git", "resolved_ref": _COMMIT, "path": "pkgs/p", "lock": ""}
    relative = dict(git, url = "../shared", path = ".", lock = str(lock))
    cases = [
        (hosted, pub_hosted_source("p", "1.0.0", _SHA, "https://pub.dev")),
        (git, pub_git_source("p", "1.0.0", git["url"], _COMMIT, "pkgs/p")),
        (relative, pub_git_source("p", "1.0.0", "../shared", _COMMIT, lock = lock)),
    ]

    # A source repository reads what its files repository wrote, through the
    # files repository's root.
    def read_back(files):
        rctx = struct(
            path = lambda _label: struct(dirname = struct(get_child = lambda name: name)),
            read = lambda path, watch = "auto": files[path],
        )
        return pub_files_fetched(rctx, Label("@@files//:BUILD.bazel"))

    for fetched, source in cases:
        files, rctx = _recording_context()
        write_pub_files_root(rctx, fetched)
        asserts.true(env, files["pub_files.bzl"].startswith("FILES = {"), files["pub_files.bzl"])
        got = read_back(files)
        asserts.equals(env, struct(package_name = "p", version = "1.0.0", source = source), got)

    # Files whose repository records nothing state no source.
    files, rctx = _recording_context()
    write_pub_files_root(rctx)
    asserts.equals(env, "FILES = None\n", files["pub_files.bzl"])
    asserts.equals(env, None, read_back(files))
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
_relative_git_identity_test = unittest.make(_relative_git_identity_test_impl)
_spoke_files_test = unittest.make(_spoke_files_test_impl)
_sdk_test = unittest.make(_sdk_test_impl)
_path_identity_test = unittest.make(_path_identity_test_impl)
_files_record_test = unittest.make(_files_record_test_impl)

def purl_test_suite(name):
    """Registers the purl unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    small_unittest_suite(name, _hosted_test, _git_test, _relative_git_identity_test, _spoke_files_test, _sdk_test, _path_identity_test, _files_record_test)
