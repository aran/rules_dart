# Bazel rules for Dart

Bazel rule set for building Dart applications and libraries.

## Installation

### Using bzlmod (Bazel 6+)

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dart", version = "0.0.0")

dart = use_extension("@rules_dart//dart:extensions.bzl", "dart")
dart.toolchain(dart_version = "3.11.0")
use_repo(dart, "dart_toolchains")

register_toolchains("@dart_toolchains//:all")
```

### Using WORKSPACE

From the release you wish to use:
<https://github.com/aran/rules_dart/releases>
copy the WORKSPACE snippet into your `WORKSPACE` file.

To use a commit rather than a release, you can point at any SHA of the repo.

For example to use commit `abc123`:

1. Replace `url = "https://github.com/aran/rules_dart/releases/download/v0.1.0/rules_dart-v0.1.0.tar.gz"` with a GitHub-provided source archive like `url = "https://github.com/aran/rules_dart/archive/abc123.tar.gz"`
1. Replace `strip_prefix = "rules_dart-0.1.0"` with `strip_prefix = "rules_dart-abc123"`
1. Update the `sha256`. The easiest way to do this is to comment out the line, then Bazel will
   print a message with the correct value. Note that GitHub source archives don't have a strong
   guarantee on the sha256 stability, see
   <https://github.blog/2023-02-21-update-on-the-future-stability-of-source-code-archives-and-hashes/>
