"""A pubspec pub refuses, recorded so that only the builds reaching it fail.

A lock is fetched whole by `bazel fetch --all` and `bazel vendor`, packages no
build uses among them, so a source repository records the refusal instead of
failing, and every library repository reaching the package fails its build with
it.
"""

visibility("//dart/pub/...")

PUBSPEC_REFUSAL = "pubspec_refusal.txt"

def write_pubspec_refusal(ctx, refusal):
    """Records in a source repository why pub refuses its pubspec.

    Args:
      ctx: The source repository's `repository_ctx`.
      refusal: `read_pubspec`'s `error`: the message, or None.
    """
    ctx.file(PUBSPEC_REFUSAL, refusal or "")

def read_pubspec_refusal(ctx, repo):
    """Reads what `write_pubspec_refusal` recorded in another repository.

    Args:
      ctx: The reading repository's `repository_ctx`.
      repo: The source repository's name, as the extension making both gave it.

    Returns:
      The message, or None.
    """
    sibling = "@@" + ctx.name[:len(ctx.name) - len(ctx.original_name)] + repo
    return ctx.read(Label("{}//:{}".format(sibling, PUBSPEC_REFUSAL))) or None

def failing_target(name, message):
    """A target that fails the build using it with `message`, as a whole BUILD file.

    Args:
      name: The target's name.
      message: What is wrong.

    Returns:
      The file's text.
    """
    return """\
load("@rules_dart//dart/private:sdk_error.bzl", "dart_sdk_error")

dart_sdk_error(
    name = "{name}",
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = name, message = json.encode(message))
