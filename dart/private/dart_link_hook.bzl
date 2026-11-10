"""The `dart_link_hook` rule.

Runs the `hook/link.dart` of every package in a `dart_library` closure over an
executable's recorded uses, and collects the data assets the program ships.
This is the Bazel counterpart of the link step `dart build` runs: there, each
package's link hook sees which of its `@RecordUse` definitions survived
tree-shaking and decides what to ship.

A package's build hook, when linking is enabled, routes its data assets to the
package's own link hook (`ToLinkHook`), which receives them as
`LinkInput.assets` and emits what of them the program needs. The data assets a
`dart_package_metadata` declares stand in for what that build hook emits, so a
package with a link hook hands its declared ones to the hook, and the declared
assets of packages without one ship as they are. What the target provides is
both: the program's data assets after linking.

One action per package with a link hook, each hermetic: the hook runs on the
exec toolchain's `dart` against a `package_config.json` synthesised from the
closure, with the recorded uses and the closure's sources and resources as its
only inputs. A hook's own package is assembled into one directory holding just
the files Bazel declared for it (generated and source files together, its
resources, and the hook), and the hook runs from there, so it cannot read a
file of its package that no target declares.

Bazel declares every output before anything runs, so the data assets a hook
will emit are named up front in `data_assets`, by asset id. A hook emitting
an asset that is not declared, or not emitting one that is, fails the action
and lists both sets.
"""

load("//dart:providers.bzl", "DartDataAssetInfo", "DartInfo", "DartRecordedUsesInfo")
load(
    "//dart/private:common.bzl",
    "PATH_MAPPING",
    "SDK_ENV",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "executable_package_record",
    "format_literal",
    "package_identity_attrs",
    "package_link_hook",
    "program_packages",
    "resolve_package_identity",
    "unique_data_assets",
)
load("//dart/private:dart_data_asset.bzl", "data_asset", "parse_data_asset_ids")
load("//dart/private:dart_info.bzl", "package_lib_prefix")
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_sdk")
load(
    "//dart/private:project_staging.bzl",
    "project_layout",
    "resolve_package_exec_roots_from_outside",
    "staged_package_config_content",
)
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

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

def recorded_uses_package_error(label, program, named):
    """Checks that a `dart_link_hook` names the package of the program it links.

    Args:
      label: The rule's label, for messages.
      program: The `dart_package_metadata` label of the program whose uses
        `recorded_uses` provides, or None when it is in no package.
      named: The one the rule's `package` names, or None.

    Returns:
      An error string, or None when they are the same.
    """
    if program == named:
        return None
    return ("%s: `recorded_uses` is the uses of a program in the package " +
            "%s, but `package` names %s. The program's own package is linked " +
            "with its `deps`: its link hook runs and its data assets ship. " +
            "Name the program's `dart_package_metadata` in `package`.") % (
        label,
        "declared by `%s`" % program if program != None else "of no `dart_package_metadata`",
        "`%s`" % named if named != None else "none",
    )

def package_files_error(label, package, files):
    """Checks that a program's own package files are in its package's `lib/`.

    Args:
      label: The rule's label, for messages.
      package: The program's own `DartPackageInfo`, or None.
      files: The `package_files` given with it.

    Returns:
      An error string, or None.
    """
    if package == None:
        if files:
            return ("%s: `package_files` %s are given for a program in no " +
                    "package. Pass the program's own package with them.") % (
                label,
                [f.short_path for f in files],
            )
        return None
    prefix = package_lib_prefix(package.package_root)
    outside = [f.short_path for f in files if not f.short_path.startswith(prefix)]
    if outside:
        return ("%s: `package_files` %s are not under `%s`, the `lib/` of " +
                "package `%s`. Pass only the program's own files its link " +
                "hook can import.") % (label, outside, prefix, package.package_name)
    return None

def _recorded_uses(ctx, package):
    target = ctx.attr.recorded_uses
    if DartRecordedUsesInfo in target:
        info = target[DartRecordedUsesInfo]
        err = recorded_uses_package_error(
            ctx.label,
            info.package,
            package.metadata if package != None else None,
        )
        if err != None:
            fail(err)
        return info.file, info.package_files
    files = target[DefaultInfo].files.to_list()
    err = recorded_uses_file_error(ctx.label, files)
    if err != None:
        fail(err)
    return files[0], []

def link_hook_runner_attr():
    """The private attribute a rule calling `dart_link_hook_actions` declares.

    Returns:
      A dict to merge into the rule's `attrs`; pass `ctx.executable.
      _link_hook_runner` as `runner`.
    """
    return {
        "_link_hook_runner": attr.label(
            default = "//dart/private/tools:link_hook_runner",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
    }

def dart_link_hook_actions(ctx, runner, recorded_uses, package, package_files, deps, data_asset_ids, name):
    """Registers the link-hook actions for a closure; what `dart_link_hook` runs.

    For a rule that compiles its own kernel and so cannot depend on a
    `dart_link_hook` target without a cycle. A hook reads uses and writes
    data files, the same whichever host runs it, so the hooks run in
    `PORTABLE`: the caller's rule declares `PORTABLE_EXEC_GROUPS` and merges
    `link_hook_runner_attr()` into its `attrs`.

    Args:
      ctx: The rule context; it declares `COPY_TO_DIRECTORY_TOOLCHAINS` in its
        `toolchains`, which assembles each hook's package.
      runner: The link-hook runner executable (`ctx.executable._link_hook_runner`).
      recorded_uses: The recorded-uses JSON File.
      package: The program's own `DartPackageInfo`, or `None` for a program
        in no package. Its link hook runs and its data assets ship as a
        dependency's do (`program_packages`).
      package_files: The program's own Files under that package's `lib/`
        (its sources and resources there; `[]` when it has none), which the
        package's link hook may import as any package's hook imports its
        own `lib/`. A file elsewhere fails.
      deps: Targets providing `DartInfo`; their closure is linked with the
        program's own package.
      data_asset_ids: The ids of the assets the hooks emit, each
        `package:<package>/<name>`.
      name: Prefix for declared outputs, unique within the package.

    Returns:
      A struct: `assets` (a list of `struct(package, name, file, id)`, the
      content of `DartDataAssetInfo`: the program's data assets after linking,
      what the hooks emit and the declared assets of packages without a hook),
      and `validation_outputs` (Files to put in an `_validation` output group,
      so every hook runs whenever the target builds even if it emits no
      asset).
    """
    sdk = portable_sdk(ctx)
    emitted, err = parse_data_asset_ids(ctx.label, data_asset_ids)
    if err != None:
        fail(err)

    packages = program_packages(package, deps)
    hooks = {
        pkg.package_name: package_link_hook(pkg)
        for pkg in packages
        if package_link_hook(pkg) != None
    }
    for asset in emitted:
        if asset.package not in hooks:
            fail(("%s: data asset `%s` is declared for package `%s`, which has " +
                  "no link hook in the program's packages. Packages with one: %s.") %
                 (ctx.label, asset.id, asset.package, sorted(hooks.keys()) or "none"))

    # The data assets the packages' build hooks would emit, as their
    # `dart_package_metadata` declares them. A package with a link hook hands
    # its own to the hook, which decides what of them ships, as a build hook
    # does when linking is enabled; the others ship as they are.
    package_assets, err = unique_data_assets(packages)
    if err != None:
        fail(err)
    hook_inputs = {name: [] for name in hooks}
    asset_infos = []
    for asset in package_assets:
        if asset.package in hooks:
            hook_inputs[asset.package].append(asset)
        else:
            asset_infos.append(asset)

    err = package_files_error(ctx.label, package, package_files)
    if err != None:
        fail(err)
    srcs = depset(package_files, transitive = [collect_transitive_srcs(deps)])
    resources = collect_transitive_resources(deps)
    package_config = ctx.actions.declare_file(name + ".package_config.json")

    # Each hook's package is assembled into one directory of the files Bazel
    # declared for it, the hook among them, so generated and source files sit
    # together and nothing else of the package is there. The other packages are
    # read where their files are, or assembled when those have no one root.
    layout = project_layout(packages, srcs.to_list() + resources.to_list(), [])
    dep_files = {key: list(files) for key, files in layout.dep_files.items()}
    hook_keys = {}
    for pkg in packages:
        if pkg.package_name in hooks:
            key = (pkg.package_name, pkg.package_root)
            hook_keys[pkg.package_name] = key
            dep_files.setdefault(key, []).append(hooks[pkg.package_name])
    roots = resolve_package_exec_roots_from_outside(
        ctx,
        name,
        dep_files,
        package_config,
        assemble = {key: True for key in hook_keys.values()},
    )
    ctx.actions.write(
        output = package_config,
        content = staged_package_config_content(
            packages,
            {key: root.root_uri for key, root in roots.items()},
        ),
    )
    package_inputs = [package_config] + layout.src_files
    for root in roots.values():
        package_inputs.extend(root.files)

    link_outputs = []
    for package_name in sorted(hooks.keys()):
        root = roots[hook_keys[package_name]]
        link_output = ctx.actions.declare_file(
            "%s/%s.link_output.json" % (name, package_name),
        )
        link_outputs.append(link_output)
        args = ctx.actions.args()
        args.add("--dart", sdk.dart)
        args.add("--packages", package_config)
        args.add("--package-name", package_name)

        # The assembled tree's path is the mapped one under path mapping, which
        # a string built from it would not be; only a repository-relative
        # sub-path (a package that sits in a subdirectory of an external
        # repository) is appended as text.
        args.add("--package-root")
        args.add_all(
            [root.tree],
            format_each = "%s" + format_literal(root.root[len(root.tree.path):]),
            expand_directories = False,
        )
        args.add("--recorded-uses", recorded_uses)
        args.add("--output", link_output)
        inputs = [asset.file for asset in hook_inputs[package_name]]
        for asset in hook_inputs[package_name]:
            args.add("--input-data-asset", asset.file, format = format_literal(asset.name) + "=%s")
        outputs = [link_output]
        for asset in emitted:
            if asset.package != package_name:
                continue
            out = ctx.actions.declare_file(
                "%s/%s/%s" % (name, package_name, asset.name),
            )
            outputs.append(out)
            args.add("--data-asset", out, format = format_literal(asset.name) + "=%s")
            asset_infos.append(data_asset(asset.package, asset.name, out))
        ctx.actions.run(
            executable = runner,
            arguments = [args],
            inputs = depset(
                [recorded_uses] + package_inputs + inputs,
                # The hook is a script, which `dart` runs in the VM.
                transitive = [sdk.files.run],
            ),
            outputs = outputs,
            mnemonic = "DartLinkHook",
            exec_group = PORTABLE,
            progress_message = "Running link hook of %s for %s" % (package_name, ctx.label),
            env = SDK_ENV,
            execution_requirements = PATH_MAPPING,
        )
    return struct(assets = asset_infos, validation_outputs = link_outputs)

def _dart_link_hook_impl(ctx):
    identity = resolve_package_identity(ctx)
    package = executable_package_record(ctx.label, identity) if identity.metadata != None else None

    # A program's own files in its package's `lib/` come with its uses; a
    # plain JSON file brings none, and the package's files are its libraries'.
    recorded_uses, package_files = _recorded_uses(ctx, package)
    result = dart_link_hook_actions(
        ctx,
        runner = ctx.executable._link_hook_runner,
        recorded_uses = recorded_uses,
        package = package,
        package_files = package_files,
        deps = ctx.attr.deps,
        data_asset_ids = ctx.attr.data_assets,
        name = ctx.label.name,
    )
    return [
        DefaultInfo(files = depset([a.file for a in result.assets])),
        DartDataAssetInfo(assets = depset(result.assets)),
        # A hook whose package declares no data assets has only its link
        # output, which nothing else asks for. As a validation output it still
        # runs whenever this target is built, so a hook that refuses the
        # program's uses fails the build either way.
        OutputGroupInfo(_validation = depset(result.validation_outputs)),
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
            doc = """`dart_library` targets whose closure is linked, with the program's own \
`package`. Every package there with a `link_hook` has its hook run, receiving the `data_assets` \
its `dart_package_metadata` declares as `LinkInput.assets`; the declared data assets of packages \
without one are provided as they are. Usually the same `deps` as the `dart_binary` named in \
`recorded_uses`.""",
            providers = [DartInfo],
        ),
        "data_assets": attr.string_list(
            doc = """The ids (`package:<package>/<name>`) of the data assets the hooks emit. \
Bazel needs every output named before the hooks run, so each one is declared here; the build \
fails if a hook emits an asset not listed, or does not emit one that is. Each lands at \
`<target>/<package>/<name>` and is provided through `DartDataAssetInfo`, beside the declared \
data assets of packages without a link hook.""",
        ),
    } | package_identity_attrs(doc = """The `dart_package_metadata` of the program's own \
package, the `package` of the `dart_binary` named in `recorded_uses` (which must agree). It is \
linked as a package in `deps` is: its link hook runs and its data assets ship. Unset, the \
program is in no package.""") | link_hook_runner_attr(),
    provides = [DartDataAssetInfo],
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Runs the `hook/link.dart` of each package in `deps` over an executable's recorded uses and provides the data assets the program ships.",
)
