"""A Dart SDK source checkout for `dart_kernel_source(path = ...)`'s test.

`kernel_checkout_files` extracts the pinned release's `pkg/kernel` and
`pkg/_fe_analyzer_shared` into the layout of a checkout (`pkg/<package>`).
The `kernel_checkout` extension declares `@kernel_checkout_source`, a
`dart_kernel_source` on that directory: `path` is an absolute path, which only
a repository's location gives.
"""

load("//dart:repositories.bzl", "dart_kernel_source")
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

def _impl(ctx):
    root = ctx.path(Label("@kernel_checkout_files//:BUILD.bazel")).dirname
    dart_kernel_source(name = "kernel_checkout_source", path = str(root))
    return ctx.extension_metadata(reproducible = True)

kernel_checkout = module_extension(_impl)
