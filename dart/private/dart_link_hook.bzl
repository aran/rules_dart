"""The `dart_link_hook` rule.

Runs the `hook/link.dart` of every package in a `dart_library` closure over an
executable's recorded uses, and collects the data assets the hooks emit. This
is the Bazel counterpart of the link step `dart build` runs: there, each
package's link hook sees which of its `@RecordUse` definitions survived
tree-shaking and decides what to ship.

One action per package with a link hook, each hermetic: the hook runs on the
exec toolchain's `dart` against a `package_config.json` synthesised from the
closure, with the recorded uses, the closure's sources and the package's own
`lib/` files as its only inputs.

Bazel declares every output before anything runs, so the data assets a hook
will emit are named up front in `data_assets`, by asset id. A hook emitting
an asset that is not declared, or not emitting one that is, fails the action
and lists both sets.
"""

load("//dart:providers.bzl", "DartDataAssetInfo", "DartInfo", "DartRecordedUsesInfo")
load(
    "//dart/private:common.bzl",
    "collect_packages",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "generate_package_config",
    "package_link_hook",
    "writable_home_env",
)

def parse_data_asset_ids(label, ids):
    """Splits declared data asset ids into package and name.

    Args:
      label: The rule's label, for messages.
      ids: The `data_assets` strings, each `package:<package>/<name>`.

    Returns:
      `(assets, error)`: a list of `struct(package, name, id)` in declaration
      order, and None; or None and an error string.
    """
    assets = []
    seen = {}
    for asset_id in ids:
        rest = asset_id[len("package:"):] if asset_id.startswith("package:") else ""
        package, _, name = rest.partition("/")
        segments = name.split("/")
        if not package or not name or "" in segments or "." in segments or ".." in segments:
            return None, ("%s: data asset id `%s` is not of the form " +
                          "`package:<package>/<name>`, with `<name>` a relative " +
                          "path.") % (label, asset_id)
        if asset_id in seen:
            return None, "%s: data asset id `%s` is declared twice." % (label, asset_id)
        seen[asset_id] = True
        assets.append(struct(package = package, name = name, id = asset_id))
    return assets, None

def recorded_uses_file_error(label, files):
    """Checks a `recorded_uses` target without `DartRecordedUsesInfo`.

    Args:
      label: The rule's label, for messages.
      files: The target's `DefaultInfo` files.

    Returns:
      An error string, or None when it is a single `.json` file.
    """
    if len(files) == 1 and files[0].extension == "json":
        return None
    return ("%s: `recorded_uses` must provide `DartRecordedUsesInfo` (a " +
            "`dart_binary` with `record_use = True`) or be a single `.json` " +
            "file; got %s.") % (label, [f.short_path for f in files])

def link_hook_package_root(hook):
    """The exec path of the package root a `hook/link.dart` belongs to.

    Args:
      hook: The package's `hook/link.dart` File.

    Returns:
      The directory containing `hook/`; `.` for a hook at the exec root.
    """
    suffix = "hook/link.dart"
    root = hook.path[:-len(suffix)].rstrip("/")
    return root if root else "."

def _recorded_uses(ctx):
    target = ctx.attr.recorded_uses
    if DartRecordedUsesInfo in target:
        return target[DartRecordedUsesInfo].file
    files = target[DefaultInfo].files.to_list()
    err = recorded_uses_file_error(ctx.label, files)
    if err != None:
        fail(err)
    return files[0]

def _dart_link_hook_impl(ctx):
    sdk = ctx.toolchains["//dart:exec_tools_toolchain_type"].dart_sdk_info
    recorded_uses = _recorded_uses(ctx)

    declared, err = parse_data_asset_ids(ctx.label, ctx.attr.data_assets)
    if err != None:
        fail(err)

    packages = collect_packages(ctx.attr.deps)
    hooks = {
        pkg.package_name: package_link_hook(pkg)
        for pkg in packages
        if package_link_hook(pkg) != None
    }
    for asset in declared:
        if asset.package not in hooks:
            fail(("%s: data asset `%s` is declared for package `%s`, which has " +
                  "no link hook in `deps`. Packages with one: %s.") %
                 (ctx.label, asset.id, asset.package, sorted(hooks.keys()) or "none"))

    srcs = collect_transitive_srcs(ctx.attr.deps)
    resources = collect_transitive_resources(ctx.attr.deps)
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = generate_package_config(packages, srcs.to_list(), package_config),
    )

    asset_infos = []
    link_outputs = []
    for package_name in sorted(hooks.keys()):
        hook = hooks[package_name]
        link_output = ctx.actions.declare_file(
            "%s/%s.link_output.json" % (ctx.label.name, package_name),
        )
        link_outputs.append(link_output)
        args = ctx.actions.args()
        args.add("--dart", sdk.dart)
        args.add("--packages", package_config)
        args.add("--package-name", package_name)
        args.add("--package-root", link_hook_package_root(hook))
        args.add("--hook", hook)
        args.add("--recorded-uses", recorded_uses)
        args.add("--output", link_output)
        outputs = [link_output]
        for asset in declared:
            if asset.package != package_name:
                continue
            out = ctx.actions.declare_file(
                "%s/%s/%s" % (ctx.label.name, package_name, asset.name),
            )
            outputs.append(out)
            args.add("--data-asset", "%s=%s" % (asset.name, out.path))
            asset_infos.append(struct(
                package = asset.package,
                name = asset.name,
                file = out,
                id = asset.id,
            ))
        ctx.actions.run(
            executable = ctx.executable._runner,
            arguments = [args],
            inputs = depset(
                [hook, package_config, recorded_uses],
                transitive = [srcs, resources, sdk.tool_files],
            ),
            outputs = outputs,
            mnemonic = "DartLinkHook",
            progress_message = "Running link hook of %s for %s" % (package_name, ctx.label),
            env = writable_home_env(sdk.dart, link_output),
        )

    asset_files = [a.file for a in asset_infos]
    return [
        DefaultInfo(files = depset(asset_files)),
        DartDataAssetInfo(assets = depset(asset_infos)),
        # A hook whose package declares no data assets has only its link
        # output, which nothing else asks for. As a validation output it still
        # runs whenever this target is built, so a hook that refuses the
        # program's uses fails the build either way.
        OutputGroupInfo(_validation = depset(link_outputs)),
    ]

dart_link_hook = rule(
    implementation = _dart_link_hook_impl,
    attrs = {
        "recorded_uses": attr.label(
            doc = """The uses the hooks see as `LinkInput.recordedUses`: a `dart_binary` with \
`record_use = True` (anything providing `DartRecordedUsesInfo`), or a single `.json` file in the \
format the Dart compiler writes.""",
            mandatory = True,
            # Not `[".json"]`: that would reject a `dart_binary`, whose files
            # are its executable. `recorded_uses_file_error` checks the rest.
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = """`dart_library` targets whose closure is linked. Every package in it with a \
`link_hook` has its hook run; packages without one are skipped. Usually the same `deps` as the \
`dart_binary` named in `recorded_uses`.""",
            providers = [DartInfo],
        ),
        "data_assets": attr.string_list(
            doc = """The ids (`package:<package>/<name>`) of the data assets the hooks emit. \
Bazel needs every output named before the hooks run, so each one is declared here; the build \
fails if a hook emits an asset not listed, or does not emit one that is. Each lands at \
`<target>/<package>/<name>` and is provided through `DartDataAssetInfo`.""",
        ),
        "_runner": attr.label(
            default = "//dart/private/tools:link_hook_runner",
            executable = True,
            cfg = "exec",
        ),
    },
    provides = [DartDataAssetInfo],
    toolchains = ["//dart:exec_tools_toolchain_type"],
    doc = "Runs the `hook/link.dart` of each package in `deps` over an executable's recorded uses and collects the data assets they emit.",
)
