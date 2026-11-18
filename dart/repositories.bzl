"""The repository rules that fetch the Dart SDK and what is built from its source.

Each SDK, cross-compilation pair, outline stripper and summary analyzer is a
repository of its own; `dart_release_repositories` declares those of one
release. The `dart` extension declares them, and the one repository exposing
the toolchains of every SDK the root module declares.

Bazel's repository contents cache keys a repository by its canonical name, its
attributes and the `.bzl` files its rule loads. So what is fetched is held by
`http_archive`, by the load-free rule of `sdk_fetch.bzl`, or by the rules of
`sdk_source_repo.bzl`; an SDK's attributes state only the release, its toolchains
being in `@dart_toolchains`; and a release two names declare is one repository.
An edit here, or a new name for a release already held, stores none of it again.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@package_metadata//purl:purl.bzl", "purl")
load("//dart/private:local_sdk.bzl", "CROSS_TOOLS_PLACEHOLDER", "VERSION_PLACEHOLDER", "source_checkout_problem")
load("//dart/private:sdk_fetch.bzl", "dart_fetched_files")
load(
    "//dart/private:sdk_source_repo.bzl",
    "dart_source_archive_url",
    "source_tool_packages",
    _dart_analyzer_source = "dart_analyzer_source",
    _dart_kernel_source = "dart_kernel_source",
    _fetch_dart_analyzer_source = "fetch_dart_analyzer_source",
    _fetch_dart_kernel_source = "fetch_dart_kernel_source",
)
load("//dart/private:toolchain_selection.bzl", "unserved_release_error")
load("//dart/private:toolchains_repo.bzl", "CROSS_TARGETS", "PLATFORMS", "SDK_CACHE_DIR", "SDK_ERROR_LOAD", "TARGET_PLATFORMS", "cross_pair", "cross_tool_files", "dart_bin", "sdk_tool_error_target")
load("//dart/private:versions.bzl", "CROSS_TOOL_VERSIONS", "SOURCE_VERSIONS", "TOOL_VERSIONS")

########
# Remaining content of the file is only used to support toolchains.
########

# What a repository holding a Dart SDK release's files is, for every target in
# it: a `package_metadata` target and the `REPO.bazel` attaching it (an SDK's
# one BUILD file attaches it with `package()` instead, since `http_archive`
# writes no `REPO.bazel`). The purl spec has no type for the Dart SDK, and its
# `github` type names a source tree, not the prebuilt archive fetched here, so
# the identity is `generic` with the archive's `download_url` and `checksum`,
# as the spec advises for that type.
_SDK_PURL_NAME = "dart-sdk"
_IDENTITY_TARGET = "package_metadata"
_IDENTITY_REPO_FILE = 'repo(default_package_metadata = ["//:{}"])\n'.format(_IDENTITY_TARGET)

def _dart_sdk_purl(version, checksums, download_url = None):
    """The purl of files from a Dart SDK release.

    Args:
        version: The Dart SDK version.
        checksums: The SHA-256 of each file fetched, as hex.
        download_url: The one archive fetched, if one was.

    Returns:
        `pkg:generic/dart-sdk@<version>?checksum=sha256:<hex>[,...][&download_url=<url>]`.
    """
    builder = purl.builder().type("generic").name(_SDK_PURL_NAME).version(version)
    builder.add_qualifier("checksum", ["sha256:" + c for c in checksums])
    if download_url:
        builder.add_qualifier("download_url", download_url)
    return builder.build()

def _with_identity(build_content, purl_string):
    """Returns `build_content` with a `package_metadata` of `purl_string`, which `_IDENTITY_REPO_FILE` attaches (for an SDK, its BUILD file's own `package()` does)."""
    header, _, body = build_content.partition("\n")
    return """{header}
load("{rules}", "package_metadata")
{body}
package_metadata(
    name = "{target}",
    purl = "{purl}",
    visibility = ["//visibility:public"],
)
""".format(
        header = header,
        rules = str(Label("@package_metadata//rules:package_metadata.bzl")),
        body = body,
        target = _IDENTITY_TARGET,
        purl = purl_string,
    )

def _archive_base_url(version):
    """Where the Dart archive keeps a release's files; the channel is in the version's suffix."""
    channel = "stable"
    if version.endswith(".beta"):
        channel = "beta"
    elif version.endswith(".dev"):
        channel = "dev"
    return "https://storage.googleapis.com/dart-archive/channels/{channel}/release/{version}/sdk/".format(
        channel = channel,
        version = version,
    )

def _sdk_archive_url(version, platform):
    return "{base}dartsdk-{platform}-release.zip".format(base = _archive_base_url(version), platform = platform)

_SDK_FILES_TARGET = """dart_sdk_files(
    name = "sdk",
    visibility = ["//visibility:public"],
)
"""

_SDK_FILES_LOAD = 'load("@rules_dart//dart:toolchain.bzl", "dart_sdk_files")\n'

_SDK_LOAD = 'load("@rules_dart//dart:toolchain.bzl", "dart_sdk_files", "dart_toolchain")\n'

def dart_sdk_repo_attrs(dart_version, platform, sha256 = None):
    """The attributes of the `http_archive` holding one platform's SDK.

    They are part of the key Bazel stores the extracted SDK under, so they state
    the release and nothing else: no SDK's name, and none of the toolchains,
    which `@dart_toolchains` holds.

    Args:
        dart_version: The Dart SDK version.
        platform: The host platform whose SDK to fetch, a key of `PLATFORMS`.
            Cross-only targets have no SDK of their own.
        sha256: The archive's checksum; without one, `dart_version` must be
            listed in `versions.bzl`, which gives it.

    Returns:
        A dict of `http_archive`'s attributes.
    """
    version = dart_version
    if not sha256 and version not in TOOL_VERSIONS:
        fail(unserved_release_error(version, TOOL_VERSIONS.keys()))
    if platform not in PLATFORMS:
        fail("No Dart SDK for platform %s. The platforms are: %s." % (platform, ", ".join(sorted(PLATFORMS.keys()))))

    url = _sdk_archive_url(version, platform)
    sha256 = sha256 or TOOL_VERSIONS[version][platform]
    build_content = """# Generated by dart/repositories.bzl
{loads}
package(default_package_metadata = ["//:{identity}"])

exports_files(
    ["{dart}"],
    visibility = ["//visibility:public"],
)

{sdk_files}""".format(
        loads = _SDK_FILES_LOAD,
        identity = _IDENTITY_TARGET,
        dart = dart_bin(platform),
        sdk_files = _SDK_FILES_TARGET,
    )

    return {
        "build_file_content": _with_identity(build_content, _dart_sdk_purl(version, [sha256], url)),
        "sha256": sha256,
        "strip_prefix": "dart-sdk",
        "url": url,
    }

def dart_local_sdk_build_file(platform):
    """The `BUILD.bazel` of a repository laying out a Dart SDK that is not a release's archive.

    Args:
        platform: The host platform the SDK runs on, a key of `PLATFORMS`.

    Returns:
        The file, with `VERSION_PLACEHOLDER` where the SDK's version goes: only
        the SDK's own `version` file says what that is.
    """
    return """# Generated by dart/repositories.bzl
{loads}
{sdk_files}
dart_toolchain(
    name = "dart_toolchain",
    dart = "{dart_bin}",
    sdk = ":sdk",
    version = "{version}",
    exec_os = "{exec_os}",
    exec_arch = "{exec_arch}",
)
""".format(
        loads = _SDK_LOAD,
        sdk_files = _SDK_FILES_TARGET,
        dart_bin = dart_bin(platform),
        version = VERSION_PLACEHOLDER,
        exec_os = PLATFORMS[platform].dart_os,
        exec_arch = PLATFORMS[platform].dart_arch,
    )

def dart_local_cross_sdk_build_file(platform, target_platform):
    """The `BUILD.bazel` of a repository laying out a local SDK to cross-compile with.

    Args:
        platform: The host platform the SDK runs on, a key of `PLATFORMS`.
        target_platform: The cross target, a key of `TARGET_PLATFORMS`.

    Returns:
        The file, with `VERSION_PLACEHOLDER` where the SDK's version goes and
        `CROSS_TOOLS_PLACEHOLDER` where the attributes saying which cross tools
        it has go.
    """
    target_meta = TARGET_PLATFORMS[target_platform]
    return """# Generated by dart/repositories.bzl
{loads}
{sdk_files}
dart_toolchain(
    name = "dart_toolchain_cross_{target_platform}",
{cross_tools}
    dart = "{dart_bin}",
    sdk = ":sdk",
    version = "{version}",
    target_os = "{target_os}",
    target_arch = "{target_arch}",
    exec_os = "{exec_os}",
    exec_arch = "{exec_arch}",
)
""".format(
        loads = _SDK_LOAD,
        sdk_files = _SDK_FILES_TARGET,
        target_platform = target_platform,
        cross_tools = CROSS_TOOLS_PLACEHOLDER,
        dart_bin = dart_bin(platform),
        version = VERSION_PLACEHOLDER,
        target_os = target_meta.dart_os,
        target_arch = target_meta.dart_arch,
        exec_os = PLATFORMS[platform].dart_os,
        exec_arch = PLATFORMS[platform].dart_arch,
    )

def dart_repositories(name, dart_version, platform, sha256 = None):
    """Declares the repository holding a Dart SDK for one platform.

    Args:
        name: The repository's name.
        dart_version: The Dart SDK version.
        platform: The host platform whose SDK to fetch, a key of `PLATFORMS`.
        sha256: The archive's checksum, for a version `versions.bzl` does not list.
    """
    http_archive(
        name = name,
        **dart_sdk_repo_attrs(dart_version, platform, sha256)
    )

def dart_cross_tools_attrs(dart_version, exec_platform, target_platform, gen_snapshot_sha256 = None, dartaotruntime_sha256 = None):
    """The attributes of the `dart_fetched_files` holding what one pair cross-compiles with.

    Args:
        dart_version: The Dart SDK version the files belong to.
        exec_platform: The host platform, a key of `CROSS_TARGETS`.
        target_platform: The cross target, a key of `TARGET_PLATFORMS`.
        gen_snapshot_sha256: The SHA-256 of the pair's `gen_snapshot`, if it is
            to be fetched.
        dartaotruntime_sha256: The SHA-256 of the target's `dartaotruntime`, if
            it is to be fetched.

    Returns:
        A dict of `dart_fetched_files`' attributes.
    """
    files = cross_tool_files(exec_platform, target_platform)
    cache = "home/%s/%s" % (SDK_CACHE_DIR, dart_version)
    base = _archive_base_url(dart_version)
    sha256 = {}
    urls = {}
    executable = []
    for basename, checksum, runs in [
        (files.gen_snapshot, gen_snapshot_sha256, True),
        (files.dartaotruntime, dartaotruntime_sha256, False),
    ]:
        if not checksum:
            continue
        path = "%s/%s" % (cache, basename)
        sha256[path] = checksum
        urls[path] = base + basename
        if runs:
            executable.append(path)
    return {
        "build_file_content": _with_identity("""# Generated by dart/repositories.bzl
filegroup(
    name = "sdk_cache",
    srcs = {srcs},
    visibility = ["//visibility:public"],
)
""".format(srcs = sha256.keys()), _dart_sdk_purl(dart_version, sha256.values())),
        "executable": executable,
        "repo_file_content": _IDENTITY_REPO_FILE,
        "sha256": sha256,
        "urls": urls,
    }

def dart_cross_tools(name, dart_version, exec_platform, target_platform, gen_snapshot_sha256 = None, dartaotruntime_sha256 = None):
    """Declares the repository of what `dart compile` needs to cross-compile for one pair.

    `dart compile exe|aot-snapshot --target-os` runs a `gen_snapshot` built for
    the host-and-target pair and, for `exe`, prepends the target's
    `dartaotruntime`; before Dart 3.15 it wants that runtime for `aot-snapshot`
    too. Neither ships with the SDK: dartdev downloads them into `SDK_CACHE_DIR`
    under the user's home on first use. This repository fetches them with pinned
    checksums and lays them out the same way, so the compile action finds them
    there and never reaches the network.

    Args:
        name: The repository's name.
        dart_version: The Dart SDK version the files belong to.
        exec_platform: The host platform, a key of `CROSS_TARGETS`.
        target_platform: The cross target, a key of `TARGET_PLATFORMS`.
        gen_snapshot_sha256: The SHA-256 of the pair's `gen_snapshot`, if known.
        dartaotruntime_sha256: The SHA-256 of the target's `dartaotruntime`, if
            known.
    """
    dart_fetched_files(name = name, **dart_cross_tools_attrs(
        dart_version,
        exec_platform,
        target_platform,
        gen_snapshot_sha256,
        dartaotruntime_sha256,
    ))

# Repository rules: a load names them here.
dart_kernel_source = _dart_kernel_source
dart_analyzer_source = _dart_analyzer_source
fetch_dart_kernel_source = _fetch_dart_kernel_source
fetch_dart_analyzer_source = _fetch_dart_analyzer_source

# What a repository of `dart_sdk_source_tool` provides, for each tool.
_SOURCE_TOOL_TARGETS = {
    "kernel": "outline_tool",
    "analyzer": "summary_analyzer",
}

def _source_tool_impl(repository_ctx):
    tool = repository_ctx.attr.tool
    root, problem = source_checkout_problem(repository_ctx, source_tool_packages(tool))
    if problem:
        repository_ctx.file("BUILD.bazel", SDK_ERROR_LOAD + sdk_tool_error_target(_SOURCE_TOOL_TARGETS[tool], problem))
    else:
        fetch = {
            "kernel": fetch_dart_kernel_source,
            "analyzer": fetch_dart_analyzer_source,
        }[tool]
        fetch(repository_ctx, str(root))

    # Depends on a directory outside this repository.
    return repository_ctx.repo_metadata(reproducible = False)

_SOURCE_TOOL_DOC = """\
The outline stripper or the summary analyzer of an SDK declared by `{}`, built on that SDK's source.

Without usable source, the repository's target fails the build running it, saying why."""

_SOURCE_TOOL_ATTRS = {
    "tool": attr.string(doc = "Which tool.", mandatory = True, values = ["kernel", "analyzer"]),
    "sdk_name": attr.string(doc = "The SDK's name, for messages.", mandatory = True),
    "source": attr.label(doc = "The `DEPS` file at the root of the SDK's source."),
    "path_env": attr.string(doc = "The environment variable holding the checkout's path, when `source` is not given."),
}

dart_sdk_source_tool = repository_rule(
    _source_tool_impl,
    doc = _SOURCE_TOOL_DOC.format("dart.custom_sdk"),
    attrs = _SOURCE_TOOL_ATTRS,
)

# `local`, as the checkout's other repositories are: see `local_sdk.bzl`.
dart_checkout_source_tool = repository_rule(
    _source_tool_impl,
    doc = _SOURCE_TOOL_DOC.format("dart.checkout"),
    attrs = _SOURCE_TOOL_ATTRS,
    local = True,
)

def _missing_checksum(sdk, what, url, attribute, flag = None):
    message = """\
Dart SDK "{sdk}" has no checksum for {what}:
  {url}
Give its SHA-256 in dart.release(name = "{sdk}", {attribute}).""".format(
        sdk = sdk,
        what = what,
        url = url,
        attribute = attribute,
    )
    if flag:
        message += " Or build without it: {}.".format(flag)
    return message

def _once(declared, identity, name, declare):
    """The repository holding `identity`, declared under `name` unless one already holds it."""
    if identity not in declared:
        declared[identity] = name
        declare(name)
    return declared[identity]

def _cross_part(name, dart_version, platform, target_platform, cross_tools_sha256, declared):
    """Declares what one pair's checksums allow; returns its part of the SDK."""
    files = cross_tool_files(platform, target_platform)
    gen_snapshot_sha256 = cross_tools_sha256.get(files.gen_snapshot)
    dartaotruntime_sha256 = cross_tools_sha256.get(files.dartaotruntime)
    part = {}
    missing = {}
    for tool, basename, checksum in [
        ("gen_snapshot", files.gen_snapshot, gen_snapshot_sha256),
        ("dartaotruntime", files.dartaotruntime, dartaotruntime_sha256),
    ]:
        if not checksum:
            missing[tool] = _missing_checksum(
                name,
                "`%s`, which cross-compiling from %s to %s needs" % (basename, platform, target_platform),
                _archive_base_url(dart_version) + basename,
                'cross_tools_sha256 = {"%s": "<sha256>"}' % basename,
            )
    if missing:
        part["missing"] = missing
    if gen_snapshot_sha256 or dartaotruntime_sha256:
        part["repo"] = _once(
            declared,
            ("cross", dart_version, platform, target_platform, gen_snapshot_sha256, dartaotruntime_sha256),
            "%s_%s_cross_%s" % (name, platform, target_platform),
            lambda repo: dart_cross_tools(
                name = repo,
                dart_version = dart_version,
                exec_platform = platform,
                target_platform = target_platform,
                gen_snapshot_sha256 = gen_snapshot_sha256,
                dartaotruntime_sha256 = dartaotruntime_sha256,
            ),
        )
    return part

def dart_release_repositories(name, dart_version, declared, sdk_sha256 = None, source_sha256 = None, cross_tools_sha256 = None):
    """Declares the repositories of one published Dart SDK release.

    Creates `<name>_<platform>` for each host with a checksum,
    `<name>_<platform>_cross_<target>` for each cross-compilation pair with one,
    and, given the source's, `<name>_kernel_source` (the outline stripper) and
    `<name>_analyzer_source` (the summary analyzer). Each is fetched only when a
    build uses it. A file another SDK has declared, with the same checksum, is
    not declared again: the repository is shared, and Bazel stores it once. What
    has no checksum is no repository, and the part says what to add, so only a
    build needing it is stopped.

    Args:
        name: Base name for the repositories, the SDK's name.
        dart_version: The release.
        declared: A dict of what has been declared so far, across every SDK of
            the build, which this call adds to.
        sdk_sha256: The SHA-256 of each host's SDK archive, by `PLATFORMS` key.
            None for a release `versions.bzl` lists, which then supplies all
            three checksums.
        source_sha256: The SHA-256 of the release tag's source archive.
        cross_tools_sha256: The SHA-256 of each cross-compilation file, by
            basename.

    Returns:
        What the SDK is made of, as `toolchains_build_content` takes it.
    """
    if sdk_sha256 == None:
        if dart_version not in TOOL_VERSIONS:
            # Fails, saying which releases are served and how to declare another.
            dart_sdk_repo_attrs(dart_version, PLATFORMS.keys()[0])
        sdk_sha256 = TOOL_VERSIONS[dart_version]
        source_sha256 = SOURCE_VERSIONS.get(dart_version)
        cross_tools_sha256 = CROSS_TOOL_VERSIONS.get(dart_version, {})
    cross_tools_sha256 = cross_tools_sha256 or {}

    hosts = {}
    cross = {}
    for platform in PLATFORMS.keys():
        if platform in sdk_sha256:
            hosts[platform] = {"repo": _once(
                declared,
                ("sdk", dart_version, platform, sdk_sha256[platform]),
                "%s_%s" % (name, platform),
                lambda repo: dart_repositories(
                    name = repo,
                    dart_version = dart_version,
                    platform = platform,
                    sha256 = sdk_sha256[platform],
                ),
            )}
        else:
            hosts[platform] = {"error": _missing_checksum(
                name,
                "its %s archive" % platform,
                _sdk_archive_url(dart_version, platform),
                'sdk_sha256 = {"%s": "<sha256>"}' % platform,
            )}
        for target_platform in CROSS_TARGETS.get(platform, []):
            cross[cross_pair(platform, target_platform)] = _cross_part(
                name,
                dart_version,
                platform,
                target_platform,
                cross_tools_sha256,
                declared,
            )

    tools = {}
    url = dart_source_archive_url(dart_version)
    for tool, suffix, rule, what, flag in [
        ("kernel", "kernel_source", dart_kernel_source, "the outline stripper", "--@rules_dart//dart:outline_kernel=false"),
        ("analyzer", "analyzer_source", dart_analyzer_source, "the summary analyzer", "--@rules_dart//dart:analysis_summaries=false"),
    ]:
        if source_sha256:
            tools[tool] = {"repo": _once(
                declared,
                (suffix, dart_version, source_sha256),
                "%s_%s" % (name, suffix),
                lambda repo: rule(name = repo, dart_version = dart_version, sha256 = source_sha256),
            )}
        else:
            tools[tool] = {"error": _missing_checksum(
                name,
                "the source archive %s is built from" % what,
                url,
                'source_sha256 = "<sha256>"',
                flag,
            )}
    return {"version": dart_version, "hosts": hosts, "cross": cross, "tools": tools}
