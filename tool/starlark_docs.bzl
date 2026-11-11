"""The check that a package's public .bzl files document every public symbol."""

load("//dart:defs.bzl", "dart_test")

def starlark_docs_test(name, **kwargs):
    """Fails when a public symbol of a .bzl file of this package has no doc.

    Each file's docs are the `starlark_doc_extract` target that
    `@bazel_lib//:bzl_library.bzl`'s `bzl_library` named after the file makes,
    so a file without one fails the build.

    Args:
        name: The test's name.
        **kwargs: Passed to the `dart_test`.
    """
    docs = [
        ":%s.doc_extract.binaryproto" % f.removesuffix(".bzl")
        for f in native.glob(["*.bzl"])
    ]
    dart_test(
        name = name,
        size = "small",
        srcs = [Label(":starlark_docs.dart")],
        main = Label(":starlark_docs_check.dart"),
        args = ["$(rlocationpath %s)" % d for d in docs],
        data = docs,
        deps = [
            Label("//dart/runfiles"),
            Label("@ext_pub_deps//:protobuf"),
        ],
        **kwargs
    )
