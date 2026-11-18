"""`dart_kernel_source` declared wrongly, each in its own way: see `BUILD.bazel`."""

load("@rules_dart//dart:repositories.bzl", "dart_kernel_source")

def _impl(mctx):
    dart_kernel_source(
        name = "both",
        dart_version = "3.14.1",
        path = "/usr",
    )
    dart_kernel_source(name = "neither")
    dart_kernel_source(
        name = "not_a_checkout",
        path = "/usr",
    )
    return mctx.extension_metadata(reproducible = True)

kernel_source_refused = module_extension(implementation = _impl)
