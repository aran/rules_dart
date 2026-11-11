"""A locked `path` package that `pub.from_lock(ignored = ...)` builds nothing for.

The package's library repository holds one of these: the hub's label and every
locked package that depends on the package reach it, and analysing it fails
with the reason the user gave. Nothing fails while nothing depends on it.
"""

# Loaded by the BUILD files rules_dart writes into the repositories the `pub`
# extension creates, which are other repositories.
visibility("public")

def _pub_ignored_package_impl(ctx):
    fail(("pub.from_lock(): package `%s` (in %s) is ignored: %s. Something depends on it; " +
          "remove that dependency, or build the package: name it in `resolve` or " +
          "`build_from_pubspec` instead of `ignored`.") % (
        ctx.attr.package_name,
        ctx.attr.lock,
        ctx.attr.reason,
    ))

pub_ignored_package = rule(
    implementation = _pub_ignored_package_impl,
    attrs = {
        "package_name": attr.string(mandatory = True, doc = "The package the lock names."),
        "lock": attr.string(mandatory = True, doc = "The lock that names it ignored."),
        "reason": attr.string(mandatory = True, doc = "Why, as the user wrote it."),
    },
    doc = "Fails analysis, giving the reason a locked package is ignored.",
)
