"""Analysis-time assertion about the license file each package record names.

`license_check` fails analysis (so `bazel build //...` fails) when a package in
the target's closure names a license other than the stated file at its root.
Building it is the test.
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
