"""A dart-lang/sdk checkout with an SDK built in it, laid out from a source tree and a built SDK.

Its paths are those `tools/build.py create_sdk` leaves: the source at the root,
and in `out/Release<ARCH>` the `dart-sdk` directory, the build's own files, and
`gen_snapshot_product_<target>`. What it cannot be is a build: the SDK and the
`gen_snapshot` are a release's, so it says nothing of what a real build's files
hold, nor of `xcodebuild/`, where macOS builds go.
"""

def _host(rctx):
    name = rctx.os.name.lower()
    os = "macos" if name.startswith("mac") else "windows" if name.startswith("windows") else "linux"
    return "{}-{}".format(os, "arm64" if rctx.os.arch in ("aarch64", "arm64") else "x64")

def _standin_checkout_impl(rctx):
    host = _host(rctx)
    source = rctx.path(rctx.attr.source).dirname
    rctx.symlink(source.get_child("pkg"), "pkg")
    rctx.symlink(rctx.attr.source, "DEPS")
    sdk = rctx.path(rctx.attr.sdks[host]).dirname
    build = "Release" + host.partition("-")[2].upper()
    for entry in sdk.readdir():
        if entry.basename not in ("BUILD.bazel", "REPO.bazel"):
            rctx.symlink(entry, "out/%s/dart-sdk/%s" % (build, entry.basename))
    rctx.file("out/%s/args.gn" % build, "is_debug = false\n")
    rctx.file("out/%s/build.ninja" % build, "# What `tools/build.py` generates.\n")

    # `create_sdk` leaves these beside the SDK. Linux x86-64 has none to cross
    # to its own architecture.
    if host in rctx.attr.gen_snapshots:
        name = "gen_snapshot_product_linux_x64" + (".exe" if host.startswith("windows") else "")
        rctx.symlink(rctx.attr.gen_snapshots[host], "out/%s/%s" % (build, name))
    rctx.file("BUILD.bazel", "")

standin_checkout = repository_rule(
    _standin_checkout_impl,
    attrs = {
        "gen_snapshots": attr.string_keyed_label_dict(mandatory = True),
        "sdks": attr.string_keyed_label_dict(mandatory = True),
        "source": attr.label(mandatory = True),
    },
)
