"""A repository rule that holds files fetched for a Dart SDK, and nothing computed.

Bazel's repository contents cache keys a reproducible repository by its
attributes and by the digest of the `.bzl` file defining its rule, with
everything that file loads. Were this rule defined beside the code computing
its attributes, every edit there would store each repository's bytes again.

So this file loads nothing, and must stay that way: what a repository holds is
decided by its attributes alone, generated files included.
"""

visibility("//dart/...")

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
