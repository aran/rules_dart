"Public API for pub.dev package management."

# The pub module extension is used directly from extensions.bzl:
#   pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
#   pub.package(name = "path", version = "1.9.1", sha256 = "...")
#   use_repo(pub, "path")
#
# This file is reserved for future pub-related rules.
