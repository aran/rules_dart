"""What a program ships: the `dart_program_assets` rule and its actions.

A package's assets are facts of the package (`dart_package_metadata`): its
declared data assets, which stand in for what its build hook emits, its code
assets, its `hook/link.dart` and the ids that hook promises. What a program
ships is one operation over the program, its packages and whether it is
linked, and every consumer (a bundler, `dart_binary`, `dart_test`) takes it
from `DartProgramAssetsInfo`, so no two of them can disagree.

Unlinked (a debug build), every package's declared assets ship, all known at
analysis time, and the manifest is written then.

Linked, the Bazel counterpart of the link step `dart build` runs: each
package's link hook sees which of its `@RecordUse` definitions survived
tree-shaking and decides what ships. A package's build hook, when linking is
enabled, routes its assets to the package's own link hook (`ToLinkHook`), which
receives them as `LinkInput.assets` and emits what the program needs; the
assets of packages without a hook ship as they are. So a package with a
`link_hook` hands its declared assets to the hook.

One action per package with a link hook, each hermetic: the hook runs on the
exec toolchain's `dart` against a `package_config.json` synthesised from the
closure, with the recorded uses and the closure's sources and resources as its
only inputs. A hook's own package is assembled into one directory holding just
the files Bazel declared for it (generated and source files together, its
resources, and the hook), and the hook runs from there, so it cannot read a
file of its package that no target declares.

What a hook emits depends on the program, so its data assets land in one
output directory per package. The ids it promises in the package's
`link_hook_assets` are declared Files beside it, known at analysis time, so a
rule can name one; it must emit those and may emit more. A last action merges
what each hook emitted with the assets of the packages without one into the
manifest.
"""

load("//dart:providers.bzl", "DartInfo", "DartProgramAssetsInfo", "DartRecordedUsesInfo")
load(
    "//dart/private:common.bzl",
    "PATH_MAPPING",
    "SDK_ENV",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "executable_package_record",
    "format_literal",
    "package_code_assets",
    "package_identity_attrs",
    "package_link_hook",
    "package_link_hook_assets",
    "program_packages",
    "resolve_code_assets",
    "resolve_package_identity",
    "unique_data_assets",
)
load("//dart/private:dart_info.bzl", "package_lib_prefix")
load("//dart/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_sdk")
load("//dart/private:package_info.bzl", "parse_data_asset_ids")
load(
    "//dart/private:project_staging.bzl",
    "project_layout",
    "resolve_package_exec_roots_from_outside",
    "staged_package_config_content",
)
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")

visibility("//dart/...")

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
    """Checks that a program's assets name the package of the program whose uses link it.

    Args:
      label: The rule's label, for messages.
      program: The `dart_package_metadata` label of the program whose uses
        `recorded_uses` provides, or None when it is in no package.
      named: The one the program's own package record names, or None.

    Returns:
      An error string, or None when they are the same.
    """
    if program == named:
        return None
    return ("%s: `recorded_uses` is the uses of a program in the package " +
            "%s, but `package` names %s. The program's own package is linked " +
            "with its `deps`: its link hook runs and its assets ship. " +
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

def linked_code_assets_error(label, package_name, metadata, assets):
    """Refuses code assets a link hook would receive.

    Args:
      label: The program's label, for messages.
      package_name: The package with the link hook.
      metadata: Its `dart_package_metadata` label, or None.
      assets: Its declared `DartCodeAssetInfo`.

    Returns:
      An error string, or None when it declares none.
    """
    if not assets:
        return None
    return ("%s: package `%s` has a `link_hook` and declares code assets %s " +
            "(in %s). Linked, a build hook routes its code assets to its link " +
            "hook, and a linked program cannot yet hand code assets to a hook.") % (
        label,
        package_name,
        [a.asset_id for a in assets],
        "`%s`" % metadata if metadata != None else "its record",
    )

def program_asset_file(info, asset_id):
    """The file of one asset a program ships, known at analysis time.

    Args:
      info: The program's `DartProgramAssetsInfo`.
      asset_id: The asset's id, `package:<package>/<name>`.

    Returns:
      The File.
    """
    if asset_id in info.known:
        return info.known[asset_id]
    package = asset_id[len("package:"):].partition("/")[0] if asset_id.startswith("package:") else ""
    fail(("`%s` is not an asset this program is known to ship before it is " +
          "built. Either no package of the program declares it, or package `%s` " +
          "has a link hook, which decides when it runs whether it ships. To " +
          "name it here, list it in the `link_hook_assets` of `%s`'s " +
          "`dart_package_metadata`: its hook must then always emit it. Known: %s.") % (
        asset_id,
        package,
        package,
        sorted(info.known.keys()),
    ))

def _data_entry(asset):
    return {
        "type": "data_assets/data",
        "encoding": {"package": asset.package, "name": asset.name, "file": asset.file.path},
    }

def _code_entry(asset):
    link_mode = {"type": asset.link_mode}
    if asset.uri:
        link_mode["uri"] = asset.uri
    encoding = {"id": asset.asset_id, "link_mode": link_mode}
    if asset.file != None:
        encoding["file"] = asset.file.path
    return {"type": "code_assets/code", "encoding": encoding}

def _entry_id(entry):
    encoding = entry["encoding"]
    if "id" in encoding:
        return encoding["id"]
    return "package:%s/%s" % (encoding["package"], encoding["name"])

def _sorted_entries(entries):
    return sorted(entries, key = _entry_id)

def program_assets_attrs():
    """The private attributes a rule calling `dart_program_assets_actions` declares.

    Returns:
      A dict to merge into the rule's `attrs`.
    """
    return {
        "_link_hook_runner": attr.label(
            default = "//dart/private/tools:link_hook_runner",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
        "_program_assets_manifest": attr.label(
            default = "//dart/private/tools:program_assets_manifest",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
    }

# What a rule calling `dart_program_assets_actions` declares in `toolchains`.
PROGRAM_ASSETS_TOOLCHAINS = COPY_TO_DIRECTORY_TOOLCHAINS

def dart_program_assets_actions(ctx, package, deps, name, recorded_uses = None):
    """What a program ships; the operation `dart_program_assets` performs.

    For a rule that bundles a program itself, or compiles its own kernel and
    so cannot depend on a `dart_program_assets` target without a cycle.
    Linking runs each package's link hook, which reads uses and writes data
    files, the same whichever host runs it, so the hooks run in `PORTABLE`:
    the caller's rule declares `PORTABLE_EXEC_GROUPS`, merges
    `program_assets_attrs()` into its `attrs` and declares
    `PROGRAM_ASSETS_TOOLCHAINS` in its `toolchains`.

    Args:
      ctx: The rule context.
      package: The program's own `DartPackageInfo`, or `None` for a program
        in no package. Its assets ship and its link hook runs as a
        dependency's do: the program's packages are `program_packages(package,
        deps)`.
      deps: Targets providing `DartInfo`, whose closure is the program's.
      name: Prefix for declared outputs, unique within the package.
      recorded_uses: The program's `DartRecordedUsesInfo` to link it over
        them, or `None` not to link it. Its `package` must be `package`'s
        `dart_package_metadata`, and its `package_files` are the program's own
        files under that package's `lib/`, which the package's link hook may
        import.

    Returns:
      A struct: `info` (the program's `DartProgramAssetsInfo`) and
      `validation_outputs` (Files to put in an `_validation` output group, so
      that every link hook runs whenever the target builds, whatever its
      consumers read).
    """
    packages = program_packages(package, deps)
    data_assets, err = unique_data_assets(packages)
    if err != None:
        fail("%s: %s" % (ctx.label, err))
    code_assets = resolve_code_assets(
        ctx.label,
        [asset for pkg in packages for asset in package_code_assets(pkg)],
        [],
    )
    hooked = {}
    if recorded_uses != None:
        hooked = {pkg.package_name: pkg for pkg in packages if package_link_hook(pkg) != None}

    # The assets of packages without a link hook ship as they are, and are
    # known now; those of a package with one are its hook's input.
    shipped_data = [a for a in data_assets if a.package not in hooked]
    shipped_code = [a for a in code_assets if _asset_package(a.asset_id) not in hooked]
    entries = [_data_entry(a) for a in shipped_data] + [_code_entry(a) for a in shipped_code]
    known = {a.id: a.file for a in shipped_data}
    known.update({a.asset_id: a.file for a in shipped_code if a.file != None})
    files = [a.file for a in shipped_data] + [a.file for a in shipped_code if a.file != None]

    manifest = ctx.actions.declare_file(name + ".assets.json")
    if not hooked:
        ctx.actions.write(
            output = manifest,
            content = json.encode_indent({"assets": _sorted_entries(entries)}, indent = "  "),
        )
        return struct(
            info = DartProgramAssetsInfo(manifest = manifest, files = depset(files), known = known),
            validation_outputs = [],
        )

    for package_name, pkg in hooked.items():
        err = linked_code_assets_error(
            ctx.label,
            package_name,
            pkg.metadata,
            [a for a in code_assets if _asset_package(a.asset_id) == package_name],
        )
        if err != None:
            fail(err)

    linked = _link_hook_actions(
        ctx,
        packages = packages,
        package = package,
        hooked = hooked,
        data_assets = data_assets,
        deps = deps,
        recorded_uses = recorded_uses,
        name = name,
    )
    known.update(linked.known)
    plan = ctx.actions.declare_file(name + ".assets_plan.json")
    ctx.actions.write(
        output = plan,
        content = json.encode({"assets": entries, "packages": linked.plan}),
    )
    args = ctx.actions.args()
    args.add("--plan", plan)
    args.add("--output", manifest)
    ctx.actions.run(
        executable = ctx.executable._program_assets_manifest,
        arguments = [args],
        inputs = [plan] + linked.records,
        outputs = [manifest],
        mnemonic = "DartProgramAssets",
        exec_group = PORTABLE,
        progress_message = "Listing the assets of %{label}",
    )
    return struct(
        info = DartProgramAssetsInfo(
            manifest = manifest,
            files = depset(files + linked.outputs),
            known = known,
        ),
        validation_outputs = [manifest],
    )

def _asset_package(asset_id):
    return asset_id[len("package:"):].partition("/")[0]

def _link_hook_actions(ctx, packages, package, hooked, data_assets, deps, recorded_uses, name):
    """Runs the link hook of each package in `hooked` over the program's uses.

    Returns:
      A struct: `records` (each hook's record of what it emitted), `outputs`
      (the Files and directories its emitted assets are in), `known` (the
      promised ids' Files) and `plan` (by package, what the manifest step
      reads with each record).
    """
    sdk = portable_sdk(ctx)
    err = recorded_uses_package_error(
        ctx.label,
        recorded_uses.package,
        package.metadata if package != None else None,
    )
    if err != None:
        fail(err)
    err = package_files_error(ctx.label, package, recorded_uses.package_files)
    if err != None:
        fail(err)
    srcs = depset(recorded_uses.package_files, transitive = [collect_transitive_srcs(deps)])
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
        if pkg.package_name in hooked:
            key = (pkg.package_name, pkg.package_root)
            hook_keys[pkg.package_name] = key
            dep_files.setdefault(key, []).append(package_link_hook(pkg))
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

    records = []
    outputs = []
    known = {}
    plan = {}
    for package_name in sorted(hooked.keys()):
        pkg = hooked[package_name]

        # Checked where the record was built; parsed here for the names.
        promised, err = parse_data_asset_ids(pkg.label, package_link_hook_assets(pkg))
        if err != None:
            fail(err)
        root = roots[hook_keys[package_name]]
        record = ctx.actions.declare_file("%s/%s.link_output.json" % (name, package_name))
        directory = ctx.actions.declare_directory("%s/%s.data" % (name, package_name))
        records.append(record)
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
        if pkg.metadata != None:
            args.add("--metadata", str(pkg.metadata))
        args.add("--recorded-uses", recorded_uses.file)
        args.add("--output", record)
        args.add_all("--directory", [directory], expand_directories = False)
        inputs = [a for a in data_assets if a.package == package_name]
        for asset in inputs:
            args.add("--input-data-asset", asset.file, format = format_literal(asset.name) + "=%s")
        hook_outputs = [record, directory]
        promised_files = {}
        for asset in promised:
            out = ctx.actions.declare_file("%s/%s/%s" % (name, package_name, asset.name))
            hook_outputs.append(out)
            promised_files[asset.name] = out.path
            known[asset.id] = out
            args.add("--promised-data-asset", out, format = format_literal(asset.name) + "=%s")
        outputs.extend(hook_outputs[1:])
        plan[package_name] = {
            "record": record.path,
            "directory": directory.path,
            "promised": promised_files,
        }
        ctx.actions.run(
            executable = ctx.executable._link_hook_runner,
            arguments = [args],
            inputs = depset(
                [recorded_uses.file] + package_inputs + [a.file for a in inputs],
                # The hook is a script, which `dart` runs in the VM.
                transitive = [sdk.files.run],
            ),
            outputs = hook_outputs,
            mnemonic = "DartLinkHook",
            exec_group = PORTABLE,
            progress_message = "Running link hook of %s for %s" % (package_name, ctx.label),
            env = SDK_ENV,
            execution_requirements = PATH_MAPPING,
        )
    return struct(records = records, outputs = outputs, known = known, plan = plan)

def _recorded_uses(ctx, package):
    """The program's uses: a `dart_binary`'s, or a JSON file's in the rule's package."""
    target = ctx.attr.recorded_uses
    if target == None:
        return None
    if DartRecordedUsesInfo in target:
        return target[DartRecordedUsesInfo]
    files = target[DefaultInfo].files.to_list()
    err = recorded_uses_file_error(ctx.label, files)
    if err != None:
        fail(err)

    # Uses from anywhere: of a program in this rule's `package`, with no
    # files of its own beside its libraries'.
    return DartRecordedUsesInfo(
        file = files[0],
        kind = "aot",
        package = package.metadata if package != None else None,
        package_files = [],
    )

def _dart_program_assets_impl(ctx):
    identity = resolve_package_identity(ctx)
    package = executable_package_record(ctx.label, identity) if identity.metadata != None else None
    result = dart_program_assets_actions(
        ctx,
        package = package,
        deps = ctx.attr.deps,
        name = ctx.label.name,
        recorded_uses = _recorded_uses(ctx, package),
    )
    return [
        DefaultInfo(files = depset([result.info.manifest], transitive = [result.info.files])),
        result.info,
        # A hook that promises nothing has outputs only the manifest reads.
        # As a validation output that still runs whenever this target is built,
        # so a hook that refuses the program's uses fails the build either way.
        OutputGroupInfo(_validation = depset(result.validation_outputs)),
    ]

dart_program_assets = rule(
    implementation = _dart_program_assets_impl,
    attrs = {
        "recorded_uses": attr.label(
            doc = """Set to link the program: the uses its link hooks see as \
`LinkInput.recordedUses`, a `dart_binary` with `record_use = True` (anything providing \
`DartRecordedUsesInfo`), or a single `.json` file in the format the Dart compiler writes. Unset, \
the program is not linked, as in a debug build: no hook runs, and every package's declared assets \
ship.""",
            # Not `[".json"]`: that would reject a `dart_binary`, whose files
            # are its executable. `recorded_uses_file_error` checks the rest.
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = """`dart_library` targets whose closure is the program's, with its own \
`package`: usually the `deps` of the `dart_binary` named in `recorded_uses`. Linked, every package \
there with a `link_hook` has its hook run, receiving the `data_assets` its `dart_package_metadata` \
declares as `LinkInput.assets`; the declared assets of packages without one ship as they are.""",
            providers = [DartInfo],
        ),
    } | package_identity_attrs(doc = """The `dart_package_metadata` of the program's own \
package, the `package` of the `dart_binary` named in `recorded_uses` (which must agree). Its \
assets ship and its link hook runs as a package's in `deps` do. Unset, the program is in no \
package.""") | program_assets_attrs(),
    provides = [DartProgramAssetsInfo],
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = PROGRAM_ASSETS_TOOLCHAINS,
    doc = """The assets a program ships, as `DartProgramAssetsInfo`: its packages' data and code \
assets, after their link hooks over the program's recorded uses when `recorded_uses` is set.""",
)
