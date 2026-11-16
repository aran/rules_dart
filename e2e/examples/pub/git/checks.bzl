"""Analysis-time assertions about what each package record names.

`license_check` fails analysis (so `bazel build //...` fails) when a package in
the target's closure names a license other than the stated file at its root;
`fetched_identity_check` when one was fetched as other than the stated
repository, commit and directory. Building them is the test.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "package_license_file")

def _impl(ctx):
    got = {}
    for pkg in collect_packages(ctx.attr.deps):
        f = package_license_file(pkg)
        got[pkg.package_name] = "" if f == None else (
            f.short_path[len(pkg.package_root) + 1:] if f.short_path.startswith(pkg.package_root + "/") else f.short_path
        )
    if got != ctx.attr.license_files:
        fail("license files by package (a path relative to its root):\n  got  %s\n  want %s" % (got, ctx.attr.license_files))
    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

license_check = rule(
    implementation = _impl,
    attrs = {
        "deps": attr.label_list(mandatory = True, providers = [DartInfo]),
        "license_files": attr.string_dict(doc = "package name -> its license file's path within the package, or \"\" for none."),
    },
)

def _local_git_text(identity):
    if identity == None or identity.kind != "local_git":
        return str(identity)
    below = "#" + identity.package_path if identity.package_path else ""
    return "@@{}//{}@{}{}".format(identity.repository, identity.directory, identity.commit, below)

def _identity_impl(ctx):
    got = {pkg.package_name: _local_git_text(pkg.fetched_identity) for pkg in collect_packages(ctx.attr.deps)}
    want = {
        name: "@@{}//{}".format(ctx.attr.lock.label.repo_name, identity)
        for name, identity in ctx.attr.fetched_identities.items()
    }
    if got != want:
        fail("fetched identities by package:\n  got  %s\n  want %s" % (got, want))
    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

fetched_identity_check = rule(
    implementation = _identity_impl,
    attrs = {
        "deps": attr.label_list(mandatory = True, providers = [DartInfo]),
        "lock": attr.label(mandatory = True, allow_single_file = True, doc = "The lock the packages' relative urls are relative to."),
        "fetched_identities": attr.string_dict(doc = "package name -> `<repository>@<commit>[#<directory>]`, the repository from the lock's repository's root."),
    },
)
