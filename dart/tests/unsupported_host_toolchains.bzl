"""`dart_host_toolchains` as a machine with no Dart SDK has it, on any machine.

No CI runner is such a machine, so this repository holds what one would get, and
a test loads it and analyzes the toolchain's error. Nothing registers it.
"""

# buildifier: disable=bzl-visibility
load("//dart/private:toolchains_repo.bzl", "host_toolchains_build_content")

UNSUPPORTED_HOST_MESSAGE = "This machine has no Dart SDK."

def _unsupported_host_toolchains_impl(rctx):
    rctx.file("BUILD.bazel", host_toolchains_build_content(None, UNSUPPORTED_HOST_MESSAGE, {}, {}))

unsupported_host_toolchains = repository_rule(
    implementation = _unsupported_host_toolchains_impl,
    doc = "The toolchains of a host with no Dart SDK.",
)
