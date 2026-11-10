"""A Dart SDK source checkout for the tests of `dart_kernel_source(path = ...)` and `dart_analyzer_source(path = ...)`.

`kernel_checkout_files` extracts the pinned release's `pkg/kernel`,
`pkg/analyzer`, `pkg/linter` and `pkg/_fe_analyzer_shared` into the layout of
a checkout (`pkg/<package>`). The `kernel_checkout` extension declares
`@kernel_checkout_source` and `@analyzer_checkout_source`, a
`dart_kernel_source` and a `dart_analyzer_source` on that directory: `path` is
an absolute path, which only a repository's location gives.
`kernel_prefixed_source` and `analyzer_prefixed_source` call
`fetch_dart_kernel_source` and `fetch_dart_analyzer_source` with a prefix from
a repository rule that has a root `BUILD.bazel` of its own, as rules_flutter's
`flutter_engine_out_dirs` does.
"""

load("//dart:repositories.bzl", "dart_analyzer_source", "dart_kernel_source", "fetch_dart_analyzer_source", "fetch_dart_kernel_source")
load("//dart/private:versions.bzl", "SOURCE_VERSIONS")

_VERSION = "3.13.7"

def _files_impl(rctx):
    archive = "sdk.tar.gz"
    rctx.download(
        url = "https://github.com/dart-lang/sdk/archive/refs/tags/%s.tar.gz" % _VERSION,
        output = archive,
        sha256 = SOURCE_VERSIONS[_VERSION],
    )
    for package in ["kernel", "analyzer", "linter", "_fe_analyzer_shared"]:
        rctx.extract(
            archive,
            output = "pkg/" + package,
            stripPrefix = "sdk-%s/pkg/%s" % (_VERSION, package),
        )
    rctx.delete(archive)
    rctx.file("BUILD.bazel", "")
    return rctx.repo_metadata(reproducible = True)

kernel_checkout_files = repository_rule(_files_impl)

def _prefixed(helper, name, prefix, field, tool):
    def impl(rctx):
        # The caller's own root package, which the helper must leave alone.
        root_build = "filegroup(name = \"root_marker\", srcs = [], visibility = [\"//visibility:public\"])\n"
        rctx.file("BUILD.bazel", root_build)
        rctx.file("caller.txt", "written by the caller")
        result = helper(rctx, rctx.attr.path, prefix)
        if getattr(result, field) != "//%s:%s" % (prefix, tool):
            fail("%s returned %s" % (name, getattr(result, field)))
        if rctx.read("BUILD.bazel") != root_build or rctx.read("caller.txt") != "written by the caller":
            fail("%s changed the caller's files" % name)
        written = sorted([c.basename for c in rctx.path(".").readdir()])
        expected = sorted(["BUILD.bazel", "caller.txt", prefix])
        if written != expected:
            fail("%s wrote outside %s: %s" % (name, prefix, written))
        return rctx.repo_metadata(reproducible = False)

    return repository_rule(impl, attrs = {"path": attr.string(mandatory = True)})

kernel_prefixed_source = _prefixed(fetch_dart_kernel_source, "fetch_dart_kernel_source", "kernel_source", "outline_tool", "outline_tool")

analyzer_prefixed_source = _prefixed(fetch_dart_analyzer_source, "fetch_dart_analyzer_source", "analyzer_source", "summary_analyzer", "summary_analyzer")

def _impl(ctx):
    root = ctx.path(Label("@kernel_checkout_files//:BUILD.bazel")).dirname
    dart_kernel_source(name = "kernel_checkout_source", path = str(root))
    kernel_prefixed_source(name = "kernel_prefixed_source", path = str(root))
    dart_analyzer_source(name = "analyzer_checkout_source", path = str(root))
    analyzer_prefixed_source(name = "analyzer_prefixed_source", path = str(root))
    return ctx.extension_metadata(reproducible = True)

kernel_checkout = module_extension(_impl)
