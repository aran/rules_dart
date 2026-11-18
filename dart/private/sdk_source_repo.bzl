"""What builds rules_dart's tools on a Dart SDK's own source.

`fetch_dart_kernel_source` and `fetch_dart_analyzer_source` write, over a source
tree laid out as a checkout, the packages a tool is built on and the tool. They
hold links and generated BUILD files, so what they load does not matter to
Bazel's repository contents cache: the bytes of a release's source are in the
repository `dart_source_packages` makes (`sdk_fetch.bzl`), which loads nothing.
"""

load("//dart/private:toolchains_repo.bzl", "SDK_ERROR_LOAD", "sdk_tool_error_target")
load("//dart/pub:pubspec.bzl", "read_pubspec")

visibility("//dart/...")

def dart_source_archive_url(version):
    """The GitHub source archive of a Dart SDK release's tag.

    Args:
        version: The release.

    Returns:
        The URL.
    """
    return "https://github.com/dart-lang/sdk/archive/refs/tags/%s.tar.gz" % version

# Each tool built on an SDK's own source: the SDK packages it is built on, with
# the one they share. Those packages' other dependencies come from
# `@ext_pub_deps`, rules_dart's own pub packages.
_TOOLS = {
    "kernel": struct(
        packages = ["kernel", "_fe_analyzer_shared"],
        target = "outline_tool",
        what = "the outline stripper",
        flag = "--@rules_dart//dart:outline_kernel=false",
    ),
    "analyzer": struct(
        packages = ["analyzer", "linter", "_fe_analyzer_shared"],
        target = "summary_analyzer",
        what = "the summary analyzer",
        flag = "--@rules_dart//dart:analysis_summaries=false",
    ),
}

# The version of each package `@ext_pub_deps` has.
_PUB_VERSIONS = Label("@ext_pub_deps//:versions.json")

def source_tool_packages(tool):
    """The packages under an SDK source's `pkg/` that one tool is built on.

    Args:
        tool: `kernel`, for the outline stripper, or `analyzer`, for the summary
            analyzer.

    Returns:
        The packages' names.
    """
    return _TOOLS[tool].packages

def source_tool_target(tool):
    """The target a repository of one tool's source provides.

    Args:
        tool: `kernel` or `analyzer`.

    Returns:
        The target's name.
    """
    return _TOOLS[tool].target

def _join(prefix, *parts):
    return "/".join(([prefix] if prefix else []) + list(parts))

def _check_prefix(caller, prefix):
    if prefix and (prefix.startswith("/") or "\\" in prefix or [p for p in prefix.split("/") if p in ("", ".", "..")]):
        fail(("%s: prefix `%s` is not a relative path inside the repository: " +
              "name a directory by its path below the repository root, with `/` between its parts.") % (caller, prefix))

def _link_checkout(rctx, caller, path, prefix, packages):
    """Links `packages`' pubspecs and sources from the checkout at `path` under `prefix`."""
    root = rctx.path(path)
    for package in packages:
        source = root.get_child("pkg", package)
        pubspec = source.get_child("pubspec.yaml")

        # Watched before it is checked, so creating the file refetches.
        rctx.watch(pubspec)
        if not pubspec.exists:
            fail(("%s: %s does not exist. `path` (\"%s\") is the root of a Dart " +
                  "SDK source checkout, the directory holding `pkg/%s`; for a Flutter engine " +
                  "checkout that is `third_party/dart`.") % (caller, pubspec, path, packages[0]))
        sources = source.get_child("lib")
        rctx.watch_tree(sources)
        rctx.symlink(pubspec, _join(prefix, package, "pubspec.yaml"))
        rctx.symlink(sources, _join(prefix, package, "lib"))

def _read_packages(rctx, tool, prefix, sdk):
    """Reads the pubspecs of a tool's packages.

    Returns:
        Each package's pubspec and None, or None and why the tool cannot be built.
    """

    def problem(detail):
        return None, """\
Dart SDK "{sdk}" cannot build {what}: {detail}
Use a rules_dart whose own pub packages suit this SDK, or build without it: {flag}.""".format(
            sdk = sdk,
            what = tool.what,
            detail = detail,
            flag = tool.flag,
        )

    # A package rules_dart's lock maps elsewhere has no version here.
    available = json.decode(rctx.read(_PUB_VERSIONS))
    pubspecs = {}
    for package in tool.packages:
        read = read_pubspec(
            rctx,
            package,
            pubspec = _join(prefix, package, "pubspec.yaml"),
            locked_versions = {name: version for name, version in available.items() if version},
        )
        if read.error:
            return problem(read.error)
        for dep in read.pubspec.dependencies:
            if dep in tool.packages:
                continue
            if dep not in available:
                return problem("its pkg/%s depends on `%s`, which rules_dart's own pub packages do not include." % (package, dep))
            if dep in read.pubspec.unsatisfied:
                return problem("its pkg/%s needs `%s` %s, and rules_dart's own pub packages have %s." % (
                    package,
                    dep,
                    read.pubspec.unsatisfied[dep],
                    available[dep],
                ))
        pubspecs[package] = read.pubspec
    return pubspecs, None

def _write_packages(rctx, tool, prefix, pubspecs, build_prelude):
    """Writes a `dart_library` for each of a tool's packages under `prefix`."""
    for package, pubspec in pubspecs.items():
        deps = [
            "//" + _join(prefix, dep) if dep in tool.packages else str(Label("@ext_pub_deps//:" + dep))
            for dep in pubspec.dependencies
        ]
        rctx.file(_join(prefix, package, "BUILD.bazel"), """# Generated by dart/private/sdk_source_repo.bzl
{build_prelude}load("{defs}", "dart_library", "dart_package_metadata")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "{package}",
    language_version = "{language_version}",
)

dart_library(
    name = "{package}",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
    visibility = ["//visibility:public"],
    deps = {deps},
)
""".format(
            build_prelude = build_prelude,
            defs = str(Label("//dart:defs.bzl")),
            package = package,
            language_version = pubspec.language_version,
            deps = json.encode(deps),
        ))

def _write_tool(rctx, tool, prefix, sdk, build_prelude, build_file):
    """Writes a tool and its packages under `prefix`, or a target failing when the tool is built.

    A repository fetched for `bazel fetch --all` or `bazel vendor` fails only
    the builds running its tool. `build_file` makes the tool's BUILD file.

    Returns:
        The label of the tool, relative to the repository.
    """
    pubspecs, problem = _read_packages(rctx, tool, prefix, sdk)
    if problem:
        content = SDK_ERROR_LOAD + sdk_tool_error_target(tool.target, problem)
    else:
        _write_packages(rctx, tool, prefix, pubspecs, build_prelude)
        content = build_file()
    rctx.file(_join(prefix, "BUILD.bazel"), content)
    return "//%s:%s" % (prefix, tool.target)

def _outline_tool_build(prefix):
    return """# Generated by dart/private/sdk_source_repo.bzl
load("{defs}", "dart_binary")

# The outline stripper on this SDK's own `pkg/kernel`: for the outlines of the
# kernels this SDK's compilers write, and of no other SDK's.
dart_binary(
    name = "outline_tool",
    compile_mode = "exe",
    main = "{main}",
    visibility = ["//visibility:public"],
    deps = ["{kernel}"],
)
""".format(
        defs = str(Label("//dart:defs.bzl")),
        main = str(Label("//dart/private/tools:kernel_outline.dart")),
        kernel = "//" + _join(prefix, "kernel"),
    )

def fetch_dart_kernel_source(rctx, path, prefix = "", sdk = "", build_prelude = ""):
    """Serves a Dart SDK checkout's `pkg/kernel` and builds the outline stripper on it.

    The body of `dart_kernel_source(path = ...)`, for a repository rule that
    already reads the checkout, such as rules_flutter's `flutter_engine_out_dirs`.
    It links the checkout's `pkg/kernel` and `pkg/_fe_analyzer_shared`
    (pubspec and `lib/`) unmodified, watches them, reads their pubspecs with
    `read_pubspec`, and writes a `dart_library` for each and the stripper,
    `:outline_tool`, built on them. If it cannot be built on them, because pub
    refuses a pubspec or rules_dart's own pub packages do not suit them, building
    `:outline_tool` fails, saying so, and the caller's fetch succeeds. Everything
    is written below `prefix`, which is empty or a directory of the calling
    repository:

    - `<prefix>/kernel` and `<prefix>/_fe_analyzer_shared`: the two packages.
    - `<prefix>/BUILD.bazel`: the package holding `:outline_tool`.

    With a `prefix`, no other path is written, the root `BUILD.bazel` among
    them. With none, the repository root holds the stripper's package and the
    other two are its subdirectories, which is the whole of `dart_kernel_source`.

    The repository depends on a directory outside Bazel's control, so the caller
    must not mark itself reproducible: return `rctx.repo_metadata(reproducible = False)`.
    The checkout must be the source of the compiler whose kernels the stripper
    reads, because `pkg/kernel` reads only the kernel format of the SDK it ships
    in; that is the caller's to keep.

    Args:
      rctx: The repository context.
      path: The absolute path of the checkout's root, the directory holding
        `pkg/kernel`; for a Flutter engine checkout, `third_party/dart`.
      prefix: The directory below the repository root to write into, such as
        `kernel_source`; empty for the root.
      sdk: What to call the SDK in messages; empty for `path`.
      build_prelude: Text to start each package's BUILD file with: a `load`
        from the repository holding `path`, if that is a repository, so that
        Bazel makes it before reading through the links.

    Returns:
      `struct` with `outline_tool`, the stripper's label relative to the calling
      repository: `//kernel_source:outline_tool` for that prefix, or
      `//:outline_tool` for none. A `dart_outline_toolchain`'s `tool` names it
      as `@<repository name>` followed by this.
    """
    _check_prefix("fetch_dart_kernel_source", prefix)
    tool = _TOOLS["kernel"]
    _link_checkout(rctx, "fetch_dart_kernel_source", path, prefix, tool.packages)
    return struct(outline_tool = _write_tool(rctx, tool, prefix, sdk or path, build_prelude, lambda: _outline_tool_build(prefix)))

# The files of the summary analyzer besides its `main`.
_SUMMARY_ANALYZER_SRCS = [
    "analyze.dart",
    "args.dart",
    "context.dart",
    "doc_imports.dart",
    "guards.dart",
    "report.dart",
    "summarize.dart",
]

def _summary_analyzer_build(prefix):
    return """# Generated by dart/private/sdk_source_repo.bzl
load("{defs}", "dart_binary")

# The analyzer `--@rules_dart//dart:analysis_summaries` runs: this SDK's own
# `pkg/analyzer` and `pkg/linter`, unmodified, so that it reports what this
# SDK's `dart analyze` does.
dart_binary(
    name = "summary_analyzer",
    srcs = {srcs},
    compile_mode = "exe",
    main = "{main}",
    visibility = ["//visibility:public"],
    deps = {deps},
)
""".format(
        defs = str(Label("//dart:defs.bzl")),
        main = str(Label("//dart/private/tools:summary_analyzer.dart")),
        srcs = json.encode([str(Label("//dart/private/tools:summary_analyzer/" + f)) for f in _SUMMARY_ANALYZER_SRCS]),
        deps = json.encode(["//" + _join(prefix, "analyzer"), "//" + _join(prefix, "linter")] + [
            str(Label("@ext_pub_deps//:" + d))
            for d in ["bazel_worker", "path", "yaml"]
        ]),
    )

def fetch_dart_analyzer_source(rctx, path, prefix = "", sdk = "", build_prelude = ""):
    """Serves a Dart SDK checkout's `pkg/analyzer` and `pkg/linter` and builds the summary analyzer on them.

    The body of `dart_analyzer_source(path = ...)`, for a repository rule that
    already reads the checkout, as `fetch_dart_kernel_source` is. It links the
    checkout's `pkg/analyzer`, `pkg/linter` and `pkg/_fe_analyzer_shared`
    (pubspec and `lib/`) unmodified, watches them, and writes a `dart_library`
    for each and `:summary_analyzer`, built on them, below `prefix`. What
    stops it being built fails building it, as for `fetch_dart_kernel_source`:

    - `<prefix>/analyzer`, `<prefix>/linter` and `<prefix>/_fe_analyzer_shared`.
    - `<prefix>/BUILD.bazel`: the package holding `:summary_analyzer`.

    The caller must not mark itself reproducible. The checkout must be the
    source of the SDK whose analysis the analyzer stands in for: that is the
    caller's to keep.

    Args:
      rctx: The repository context.
      path: The absolute path of the checkout's root, the directory holding
        `pkg/analyzer`; for a Flutter engine checkout, `third_party/dart`.
      prefix: The directory below the repository root to write into, such as
        `analyzer_source`; empty for the root.
      sdk: What to call the SDK in messages; empty for `path`.
      build_prelude: As for `fetch_dart_kernel_source`.

    Returns:
      `struct` with `summary_analyzer`, the analyzer's label relative to the
      calling repository: `//analyzer_source:summary_analyzer` for that
      prefix, or `//:summary_analyzer` for none. A `dart_analyzer_toolchain`'s
      `tool` names it as `@<repository name>` followed by this.
    """
    _check_prefix("fetch_dart_analyzer_source", prefix)
    tool = _TOOLS["analyzer"]
    _link_checkout(rctx, "fetch_dart_analyzer_source", path, prefix, tool.packages)
    return struct(summary_analyzer = _write_tool(rctx, tool, prefix, sdk or path, build_prelude, lambda: _summary_analyzer_build(prefix)))
