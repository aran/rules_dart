"""The module extension declaring rules_dart's pubspec reader repositories."""

load(":reader.bzl", "pubspec_reader_repositories")

visibility("//dart/...")

def _impl(mctx):
    pubspec_reader_repositories()
    return mctx.extension_metadata(reproducible = True)

pubspec_reader = module_extension(
    implementation = _impl,
    os_dependent = False,
    arch_dependent = False,
    doc = "Declares the pubspec reader's pinned packages and a reader per host platform.",
)
