"""Repository rules that hold files fetched for a Dart SDK, and nothing computed.

Bazel's repository contents cache keys a reproducible repository by its
attributes and by the digest of the `.bzl` file defining its rule, with
everything that file loads. Were these rules defined beside the code computing
their attributes, every edit there would store each repository's bytes again.

So this file loads nothing, and must stay that way: what a repository holds is
decided by its attributes alone, generated files included.
"""

visibility("//dart/...")

# What a BUILD file reading through links into a `dart_source_packages`
# repository loads from it, so that Bazel makes that repository first. Fetching
# the repository of links does that too, but a vendored one is never fetched.
SOURCE_PACKAGES_LOAD = "source_packages.bzl"

def dart_fetched_files_impl(repository_ctx):
    """Implementation of `dart_fetched_files`, exposed so a test can run it.

    Args:
        repository_ctx: The `repository_ctx`.

    Returns:
        Metadata marking the repository reproducible.
    """
    attr = repository_ctx.attr
    for path, url in attr.urls.items():
        repository_ctx.download(
            url = url,
            output = path,
            sha256 = attr.sha256[path],
            executable = path in attr.executable,
        )
    repository_ctx.file("BUILD.bazel", attr.build_file_content)
    if attr.repo_file_content:
        repository_ctx.file("REPO.bazel", attr.repo_file_content)
    return repository_ctx.repo_metadata(reproducible = True)

def _dart_source_packages_impl(repository_ctx):
    attr = repository_ctx.attr
    archive = "sdk.tar.gz"
    repository_ctx.download(url = attr.url, output = archive, sha256 = attr.sha256)
    for package in attr.packages:
        repository_ctx.extract(
            archive,
            output = "pkg/" + package,
            stripPrefix = "%s/pkg/%s" % (attr.strip_prefix, package),
        )
    repository_ctx.delete(archive)
    repository_ctx.file("BUILD.bazel", "")
    repository_ctx.file(SOURCE_PACKAGES_LOAD, "SOURCE_PACKAGES = True\n")
    return repository_ctx.repo_metadata(reproducible = True)

dart_source_packages = repository_rule(
    _dart_source_packages_impl,
    doc = "Packages under `pkg/` of a Dart SDK source archive, laid out as in a checkout.",
    attrs = {
        "url": attr.string(doc = "The source archive.", mandatory = True),
        "sha256": attr.string(doc = "Its SHA-256.", mandatory = True),
        "strip_prefix": attr.string(doc = "The directory the archive holds the source in.", mandatory = True),
        "packages": attr.string_list(doc = "The packages to extract.", mandatory = True),
    },
)

dart_fetched_files = repository_rule(
    dart_fetched_files_impl,
    doc = "Files fetched by checksum to the given paths, with a generated `BUILD.bazel`.",
    attrs = {
        "urls": attr.string_dict(doc = "Each file's URL, by its path in the repository.", mandatory = True),
        "sha256": attr.string_dict(doc = "Each file's SHA-256, by its path in the repository.", mandatory = True),
        "executable": attr.string_list(doc = "The paths to make executable."),
        "build_file_content": attr.string(doc = "The `BUILD.bazel`.", mandatory = True),
        "repo_file_content": attr.string(doc = "The `REPO.bazel`, if any."),
    },
)
