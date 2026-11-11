"""The pubspec reader: Dart's own `package:yaml`, compiled once per host.

pub reads a pubspec with `package:yaml`. So does rules_dart: a small Dart
program (`pubspec_reader.dart`) loads the file, applies pub's checks to the
fields rules_dart reads, and prints the result as JSON, which a repository rule
decodes. Its packages are pinned here by version and sha256, outside pub
resolution, and joined by a hand-written package config; `pub get` never runs.

`pubspec_reader_<platform>` compiles the program with that platform's SDK, on a
host of that platform only, so no cache can hand one OS's binary to another.
A repository rule reaches the host's through `run_pubspec_reader`, which also
watches the program's source: the tool's output is not part of a repository's
cache key, so without the watch a reader change would leave every package read
by the old one.
"""

load("//dart/private:toolchains_repo.bzl", "PLATFORMS")
load("//dart/pub/private:pub_archive.bzl", "fetch_pub_archive")

visibility("//dart/...")

# `yaml` and its dependencies, pinned outside pub resolution:
# name -> (version, archive sha256, languageVersion from its `environment.sdk`).
READER_PACKAGES = {
    "collection": ("1.19.1", "2f5709ae4d3d59dd8f7cd309b4e023046b57d8a6c82130785d2b0e5868084e76", "3.4"),
    "path": ("1.9.1", "75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5", "3.4"),
    "pub_semver": ("2.2.1", "261236774e8b1d69cfc6b9eabbc96c40f25e7a2d6b171f3385d4f65d5734fb24", "3.4"),
    "source_span": ("1.10.2", "56a02f1f4cd1a2d96303c0144c93bd6d909eea6bee6bf5a0e0b685edbd4c47ab", "3.1"),
    "string_scanner": ("1.4.1", "921cd31725b72fe181906c6a94d987c78e3b98c2e205b397ea399d4054872b43", "3.1"),
    "term_glyph": ("1.2.2", "7f554798625ea768a7518313e58f83891c7f5024f88e46e7182a4558850a4b8e", "3.1"),
    "yaml": ("3.1.4", "f67cdd8e07d3c6329146aaef1ba043542b3134c12489f553ca9a7435d1068aea", "3.4"),
}

_SOURCE = Label("//dart/pub/private/pubspec_reader:pubspec_reader.dart")

def _executable(platform):
    return "pubspec_reader.exe" if platform.startswith("windows") else "pubspec_reader"

def _sdk_dart(platform):
    return "@dart_{p}//:bin/{exe}".format(p = platform, exe = "dart.exe" if platform.startswith("windows") else "dart")

def reader_package_repo(name):
    return "pubspec_reader_pkg_" + name

def reader_tool_repo(platform):
    return "pubspec_reader_" + platform

# The host's reader, by platform. Labels are resolved here, in rules_dart, so a
# repository rule of any module reaches them.
_TOOLS = {
    platform: Label("@{repo}//:{exe}".format(repo = reader_tool_repo(platform), exe = _executable(platform)))
    for platform in PLATFORMS
}

def host_platform(os):
    """The `PLATFORMS` key of the host a repository rule runs on.

    Args:
        os: `repository_ctx.os`.

    Returns:
        A `PLATFORMS` key, e.g. `macos-arm64`.
    """
    name = os.name.lower()
    cpu = "arm64" if os.arch in ("aarch64", "arm64") else "x64"
    if name.startswith("mac"):
        platform = "macos-" + cpu
    elif name.startswith("windows"):
        platform = "windows-" + cpu
    else:
        platform = "linux-" + cpu
    if platform not in PLATFORMS:
        fail("The Dart SDK has no build for this host ({} {}), so rules_dart cannot read pubspecs on it.".format(os.name, os.arch))
    return platform

# The ASCII characters a URI path cannot hold as they are, and their escapes.
# Other bytes (a non-ASCII path's UTF-8) pass through: the URI reader encodes them.
_URI_ESCAPES = {
    " ": "%20",
    "!": "%21",
    "\"": "%22",
    "#": "%23",
    "$": "%24",
    "%": "%25",
    "&": "%26",
    "'": "%27",
    "(": "%28",
    ")": "%29",
    "*": "%2A",
    "+": "%2B",
    ",": "%2C",
    ";": "%3B",
    "<": "%3C",
    "=": "%3D",
    ">": "%3E",
    "?": "%3F",
    "@": "%40",
    "[": "%5B",
    "\\": "%5C",
    "]": "%5D",
    "^": "%5E",
    "`": "%60",
    "{": "%7B",
    "|": "%7C",
    "}": "%7D",
}

def file_uri(path):
    """The `file:` URI of an absolute path, on any host.

    `C:\\a b\\c` is `file:///C:/a%20b/c` and `/a/b` is `file:///a/b`: the
    authority is always empty, and every ASCII character a URI path cannot
    hold is percent-encoded.

    Args:
        path: An absolute path, as `str(repository_ctx.path(...))` gives it.

    Returns:
        The URI, as a string.
    """
    path = path.replace("\\", "/")
    if not path.startswith("/"):
        path = "/" + path
    return "file://" + "".join([_URI_ESCAPES.get(ch, ch) for ch in path.elems()])

def _reader_package_impl(rctx):
    fetch_pub_archive(rctx, rctx.attr.package_name, rctx.attr.version, rctx.attr.sha256)
    rctx.file("BUILD.bazel", "")
    return rctx.repo_metadata(reproducible = True)

pubspec_reader_package = repository_rule(
    implementation = _reader_package_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
    },
    doc = "One of the pubspec reader's pinned packages.",
)

def _reader_tool_impl(rctx):
    platform = rctx.attr.platform
    host = host_platform(rctx.os)
    if host != platform:
        fail(("@{repo} is the pubspec reader for {platform} hosts, and this host is {host}. " +
              "rules_dart reads pubspecs with @{host_repo}.").format(
            repo = rctx.original_name,
            platform = platform,
            host = host,
            host_repo = reader_tool_repo(host),
        ))
    dart = rctx.path(rctx.attr.dart)
    packages = []
    for label, name in rctx.attr.packages.items():
        packages.append({
            "name": name,
            "rootUri": file_uri(str(rctx.path(label).dirname.realpath)),
            "packageUri": "lib/",
            "languageVersion": READER_PACKAGES[name][2],
        })
    rctx.file("package_config.json", json.encode_indent({
        "configVersion": 2,
        "packages": sorted(packages, key = lambda p: p["name"]),
    }) + "\n")
    rctx.file("pubspec_reader.dart", rctx.read(rctx.attr.src))
    exe = _executable(platform)
    result = rctx.execute(
        [dart, "compile", "exe", "--packages=package_config.json", "-o", exe, "pubspec_reader.dart"],
        environment = {"DASH__SUPPRESS_ANALYTICS": "true"},
        timeout = 600,
    )
    if result.return_code != 0:
        fail("Compiling rules_dart's pubspec reader failed:\n" + result.stdout + result.stderr)
    rctx.file("BUILD.bazel", 'exports_files(["{}"])\n'.format(exe))
    return rctx.repo_metadata(reproducible = True)

pubspec_reader_tool = repository_rule(
    implementation = _reader_tool_impl,
    attrs = {
        "platform": attr.string(
            doc = "The host platform this reader is built for and on.",
            mandatory = True,
            values = PLATFORMS.keys(),
        ),
        "dart": attr.label(
            doc = "That platform's `dart`.",
            mandatory = True,
            allow_single_file = True,
        ),
        "packages": attr.label_keyed_string_dict(
            doc = "Each pinned package's pubspec.yaml, keyed to the package name.",
            allow_files = True,
        ),
        "src": attr.label(mandatory = True, allow_single_file = True),
    },
    doc = "Compiles the pubspec reader for one host platform.",
)

def pubspec_reader_repositories():
    """Declares the reader's pinned packages and a reader per host platform.

    Only the host's reader, its SDK and the packages are ever fetched.
    """
    for name, (version, sha256, _) in READER_PACKAGES.items():
        pubspec_reader_package(
            name = reader_package_repo(name),
            package_name = name,
            version = version,
            sha256 = sha256,
        )
    for platform in PLATFORMS:
        pubspec_reader_tool(
            name = reader_tool_repo(platform),
            platform = platform,
            dart = _sdk_dart(platform),
            packages = {
                "@{}//:pubspec.yaml".format(reader_package_repo(name)): name
                for name in READER_PACKAGES
            },
            src = str(_SOURCE),
        )

def run_pubspec_reader(rctx, pubspec, expected_name = None):
    """Reads a pubspec with the host's reader, without failing on what it refuses.

    Args:
        rctx: The `repository_ctx`.
        pubspec: The pubspec's path, relative to the repository, as messages
            name it.
        expected_name: The name the package was fetched as, which its `name`
            field must match; None not to check.

    Returns:
        `struct(error, pubspec)`: pub's message for a pubspec it refuses, or
        None and `struct(name, dependencies, sdk_constraint, language_version, fields)`.
    """
    rctx.watch(_SOURCE)
    tool = rctx.path(_TOOLS[host_platform(rctx.os)])
    args = [tool, pubspec]
    if expected_name != None:
        args.append(expected_name)
    result = rctx.execute(args)
    out = result.stdout.strip()
    if result.return_code != 0 or not out.startswith("{"):
        fail("rules_dart's pubspec reader crashed on {} in @{}:\n{}{}".format(pubspec, rctx.original_name, result.stdout, result.stderr))
    decoded = json.decode(out)
    if "error" in decoded:
        return struct(error = decoded["error"], pubspec = None)
    ok = decoded["ok"]
    return struct(error = None, pubspec = struct(
        name = ok["name"],
        dependencies = ok["dependencies"],
        sdk_constraint = ok["sdk"] or "",
        language_version = ok["language_version"],
        fields = ok["fields"],
    ))
