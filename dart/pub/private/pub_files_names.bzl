"""The names by which a source repository finds and loads its files repository.

No loads: a files repository's rule loads this, and each `.bzl` it loads is
part of the cache key of every package's files.
"""

visibility(["//dart/pub/..."])

# The file every files repository has, by which a source repository finds it.
FILES_MARKER = "BUILD.bazel"

# The file a source repository's BUILD file loads from its files repository,
# so that Bazel makes the files repository before reading through the links.
# Fetching the source repository does that too, but a vendored one is never
# fetched, and its links would then dangle while its globs run.
FILES_LOAD = "pub_files.bzl"

def files_load_content(fetched):
    """The content of `FILES_LOAD`: `FILES`, what the files repository fetched.

    Args:
        fetched: A dict of strings, or None for files that state nothing.

    Returns:
        The file's content: Starlark, since the source repository's BUILD file
        loads it, that `read_files_load` reads back.
    """
    return "FILES = {}\n".format(json.encode(fetched) if fetched != None else "None")

def read_files_load(content):
    """What a files repository fetched, from the content of its `FILES_LOAD`.

    Args:
        content: What `files_load_content` wrote.

    Returns:
        The dict it was given, or None.
    """
    value = content.removeprefix("FILES = ").strip()
    return None if value == "None" else json.decode(value)
