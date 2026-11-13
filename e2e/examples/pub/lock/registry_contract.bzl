"""Load-time probe: the curated-registry resolver is reachable from a foreign module.

rules_flutter loads `@rules_dart//dart/ext:registry.bzl` from its own pub-spoke
generator — it generates spokes itself and so cannot reach the registry through
`pub_lock_package`. That makes cross-module loadability part of the contract,
and nothing inside rules_dart exercises it: the in-repo unit tests load the file
by its internal label, which would keep passing if the file stopped being
visible to other modules.

This workspace is a separate Bazel module depending on rules_dart, so a load
here is the real thing. Asserting at load time keeps the probe free — no target
is built, and no test needs to run for a break to surface.
"""

load("@rules_dart//dart/ext:registry.bzl", "curated_code_assets", "curated_packages")

def check_registry_contract():
    """Fails at load time if the supported resolver API has drifted."""
    packages = curated_packages()
    if "sqlite3" not in packages:
        fail("curated_packages() no longer reports sqlite3: %s" % packages)

    labels = curated_code_assets("sqlite3", "2.9.0")
    if not labels:
        fail("curated_code_assets() resolved nothing for a curated package/version")

    # A bare `//…` label would resolve against *this* module rather than
    # rules_dart, which is exactly how a downstream generator would break.
    for label in labels:
        if not label.startswith("@rules_dart//"):
            fail("curated label %r is not repo-qualified; it cannot resolve here" % label)
