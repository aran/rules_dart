"""A Dart SDK source checkout for `dart_kernel_source(path = ...)`'s test.

`kernel_checkout_files` extracts the pinned release's `pkg/kernel` and
`pkg/_fe_analyzer_shared` into the layout of a checkout (`pkg/<package>`).
The `kernel_checkout` extension declares `@kernel_checkout_source`, a
`dart_kernel_source` on that directory: `path` is an absolute path, which only
a repository's location gives.
`kernel_prefixed_source` calls `fetch_dart_kernel_source` with a prefix from a
repository rule that has a root `BUILD.bazel` of its own, as rules_flutter's
`flutter_engine_out_dirs` does.
"""

load("//dart:repositories.bzl", "dart_kernel_source", "fetch_dart_kernel_source")
load("//dart/private:versions.bzl", "SOURCE_VERSIONS")

_VERSION = "3.13.7"

def _files_impl(rctx):
    archive = "sdk.tar.gz"
    rctx.download(
        url = "https://github.com/dart-lang/sdk/archive/refs/tags/%s.tar.gz" % _VERSION,
        output = archive,
        sha256 = SOURCE_VERSIONS[_VERSION],
    )
    for package in ["kernel", "_fe_analyzer_shared"]:
        rctx.extract(
            archive,
            output = "pkg/" + package,
            stripPrefix = "sdk-%s/pkg/%s" % (_VERSION, package),
        )
    rctx.delete(archive)
    rctx.file("BUILD.bazel", "")
    return rctx.repo_metadata(reproducible = True)

kernel_checkout_files = repository_rule(_files_impl)

_PREFIX = "kernel_source"

def _prefixed_impl(rctx):
    # The caller's own root package, which the helper must leave alone.
    root_build = "filegroup(name = \"root_marker\", srcs = [], visibility = [\"//visibility:public\"])\n"
    rctx.file("BUILD.bazel", root_build)
    rctx.file("caller.txt", "written by the caller")
    kernel = fetch_dart_kernel_source(rctx, rctx.attr.path, _PREFIX)
    if kernel.outline_tool != "//%s:outline_tool" % _PREFIX:
        fail("fetch_dart_kernel_source returned %s" % kernel.outline_tool)
    if rctx.read("BUILD.bazel") != root_build or rctx.read("caller.txt") != "written by the caller":
        fail("fetch_dart_kernel_source changed the caller's files")
    written = sorted([c.basename for c in rctx.path(".").readdir()])
    expected = sorted(["BUILD.bazel", "caller.txt", _PREFIX])
    if written != expected:
        fail("fetch_dart_kernel_source wrote outside %s: %s" % (_PREFIX, written))
    return rctx.repo_metadata(reproducible = False)

kernel_prefixed_source = repository_rule(
    _prefixed_impl,
    attrs = {"path": attr.string(mandatory = True)},
)

def _impl(ctx):
    root = ctx.path(Label("@kernel_checkout_files//:BUILD.bazel")).dirname
    dart_kernel_source(name = "kernel_checkout_source", path = str(root))
    kernel_prefixed_source(name = "kernel_prefixed_source", path = str(root))
    return ctx.extension_metadata(reproducible = True)

kernel_checkout = module_extension(_impl)
