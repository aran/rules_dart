"""What a program ships: the `dart_program_assets` rule and its actions.

A package's assets are facts of the package (`dart_package_metadata`): its
declared data assets, which stand in for what its build hook emits, its code
assets, its `hook/link.dart` and the ids that hook promises. What a program
ships is one operation over the program, its packages and whether it is
linked, and every consumer (a bundler, `dart_binary`, `dart_test`) takes it
from `DartProgramAssetsInfo`, so no two of them can disagree.

Unlinked (a debug build), every package's declared assets ship, all known at
analysis time.

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
output directory per package, each at its name. The ids it promises in the
package's `link_hook_assets` are declared Files beside it, known at analysis
time, so a rule can name one; it must emit those and may emit more. Of its
package's code assets it keeps some, as they are declared, and writes the ids
of those it keeps to a file.

A consumer reads the result through `program_assets_action_args()`: one param
file Bazel writes from mapped paths, in the line format `ProgramAssets.read`
(`@rules_dart//dart/program_assets`) reads, and which the README documents.
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo", "DartProgramAssetsInfo", "DartRecordedUsesInfo")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
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
    "package_linked_code_assets",
    "program_packages",
    "resolve_code_assets",
    "resolve_package_identity",
    "target_dart_abi",
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

def program_asset_file(info, asset_id):
    """The file of one asset a program ships, known at analysis time.

    Args:
      info: The program's `DartProgramAssetsInfo`.
      asset_id: The asset's id, `package:<package>/<name>`.

    Returns:
      The File.
    """
    if asset_id in info.data_assets:
        return info.data_assets[asset_id]
    code = info.code_assets.get(asset_id)
    if code != None and code.file != None:
        return code.file
    package = asset_id[len("package:"):].partition("/")[0] if asset_id.startswith("package:") else ""
    fail(("`%s` is not an asset this program is known to ship before it is " +
          "built. Either no package of the program declares it, or package `%s` " +
          "has a link hook, which decides when it runs whether it ships. To " +
          "name it here, list it in the `link_hook_assets` of `%s`'s " +
          "`dart_package_metadata`: its hook must then always emit it. Known: %s.") % (
        asset_id,
        package,
        package,
        sorted(info.data_assets.keys() + [i for i, a in info.code_assets.items() if a.file != None]),
    ))

def program_kernel_code_assets(info):
    """Every code asset a program can load: what its kernel maps.

    The code assets that ship, and every one a link hook chose among, so the
    mapping, which is made before any hook runs, names whatever a hook keeps.
    A hook keeps an asset as its package declares it, under the same id.

    Args:
      info: The program's `DartProgramAssetsInfo`.

    Returns:
      A list of `DartCodeAssetInfo`, sorted by id.
    """
    assets = dict(info.code_assets)
    for output in info.link_outputs:
        assets.update(output.code_assets)
    return [assets[asset_id] for asset_id in sorted(assets.keys())]

# The first two lines of every file in the program-assets line format: its
# name and version, which a reader checks before anything else.
PROGRAM_ASSETS_FORMAT = "rules_dart_program_assets/1"

# How much of the code assets a tool is handed: `libraries`, each with its
# library, or `names`, what each is named and how it loads (its id, link mode,
# library's file name and uri) without the library. Either way, each link
# hook's decision of which ship.
PROGRAM_CODE_ASSET_VIEWS = ["libraries", "names"]

def _program_assets_view(data, code):
    if type(data) != "bool":
        fail("`data` is True or False; got %r." % (data,))
    if code != None and code not in PROGRAM_CODE_ASSET_VIEWS:
        fail("`code` is one of %s, or None for no code assets; got %r." % (PROGRAM_CODE_ASSET_VIEWS, code))
    if not data and code == None:
        fail("A tool handed a program's assets reads some of them: `data = True`, a `code` view, or both.")
    holds = (["data"] if data else []) + (["code"] if code == "libraries" else ["code-names"] if code == "names" else [])
    return struct(data = data, code = code, holds = " ".join(holds))

def _code_asset_lines(tag, asset, view):
    library = ""
    if asset.file != None:
        library = asset.file if view == "libraries" else asset.file.basename
    return [tag, asset.asset_id, asset.link_mode, library, asset.uri]

def program_assets_lines(info, paths, data = True, code = "libraries"):
    """A program's assets in the line format, as items: strings and Files.

    Args:
      info: The program's `DartProgramAssetsInfo`.
      paths: What the file's paths are: `exec` (relative to the execution
        root, as an action sees them) or `runfiles` (runfiles paths).
      data: Whether it holds the data assets.
      code: What it holds of the code assets: `libraries`, `names` or None.

    Returns:
      A list of strings and Files, one line each.
    """
    view = _program_assets_view(data, code)
    lines = ["--format", PROGRAM_ASSETS_FORMAT, "--paths", paths, "--holds", view.holds]
    if view.data:
        for asset_id in sorted(info.data_assets.keys()):
            lines.extend(["--data-asset", asset_id, info.data_assets[asset_id]])
        for output in info.link_outputs:
            lines.extend(["--link-data", output.package, output.data_assets])
    if view.code != None:
        for asset_id in sorted(info.code_assets.keys()):
            lines.extend(_code_asset_lines("--code-asset", info.code_assets[asset_id], view.code))
        for output in info.link_outputs:
            if output.code_selection == None:
                continue
            lines.extend(["--link-code", output.package, output.code_selection])
            for asset_id in sorted(output.code_assets.keys()):
                lines.extend(_code_asset_lines("--candidate", output.code_assets[asset_id], view.code))
    return lines

def program_assets_files(info, data = True, code = "libraries"):
    """Every File the program's assets name, as `program_assets_lines` holds them.

    Exactly the Files among its lines, so a tool is never handed a path its
    action lacks, nor an action given a file its tool is not told of. A
    library handed by name is a string, and not one of them.

    Args:
      info: The program's `DartProgramAssetsInfo`.
      data: Whether the data assets' files are among them.
      code: What of the code assets: `libraries`, `names` or None.

    Returns:
      A depset of Files.
    """
    return depset([line for line in program_assets_lines(info, "exec", data, code) if type(line) == "File"])

def program_assets_action_args(actions, info, data = True, code = "libraries"):
    """Hands an action's tool a program's assets: one flag naming one file.

    The tool is given `--program-assets=<file>`, a param file Bazel writes
    in the program-assets line format, which `ProgramAssets.read` from
    `@rules_dart//dart/program_assets` reads into the assets that ship (a
    link hook's output directory listed, its code selection applied). Bazel
    writes the file from the action's mapped command line, so its paths hold
    under path mapping, in a sandbox, in a worker and remotely.

    The tool is handed what it reads, and the action takes only those files
    as inputs: a bundler of data assets does not wait on or rerun for a
    native library, nor does a tool that only names the code assets. The file
    says what it holds, and the reader refuses to list anything else.

    Args:
      actions: `ctx.actions`.
      info: The program's `DartProgramAssetsInfo`.
      data: Whether the tool reads the data assets.
      code: What the tool reads of the code assets: `libraries`, each with
        its library; `names`, each one's id, link mode, library file name and
        uri, without the library; or None. Either view holds each link hook's
        decision of which ship.

    Returns:
      A struct: `args` (an `Args` of its own, to put in the action's
      `arguments`) and `inputs` (a depset of every File it names, to put in
      the action's `inputs`).
    """
    args = actions.args()
    args.use_param_file("--program-assets=%s", use_always = True)
    args.set_param_file_format("multiline")
    for line in program_assets_lines(info, "exec", data, code):
        if type(line) == "File":
            # A directory is passed whole, and the reader lists it.
            args.add_all([line], expand_directories = False)
        else:
            args.add(line)
    return struct(args = args, inputs = program_assets_files(info, data, code))

def _runfiles_path(ctx, f):
    return f.short_path[len("../"):] if f.short_path.startswith("../") else ctx.workspace_name + "/" + f.short_path

def _runfiles_lines(ctx, info):
    return "".join([
        (_runfiles_path(ctx, line) if type(line) == "File" else line) + "\n"
        for line in program_assets_lines(info, "runfiles")
    ])

# What an unlinked program's assets need beside `DART_ABI_CONSTRAINT_ATTRS`:
# how the target's linker names a library's exports, and, for Windows, the
# tool that lists every symbol a library's objects define, as `cc_binary`'s.
UNLINKED_PROGRAM_ASSETS_ATTRS = {
    "_def_parser": attr.label(
        default = "@bazel_tools//tools/def_parser:def_parser",
        allow_single_file = True,
        cfg = "exec",
    ),
    "_os_ios": attr.label(default = "@platforms//os:ios"),
}

def program_assets_attrs():
    """The private attributes a rule calling `dart_program_assets_actions` declares.

    Returns:
      A dict to merge into the rule's `attrs`.
    """
    return DART_ABI_CONSTRAINT_ATTRS | UNLINKED_PROGRAM_ASSETS_ATTRS | {
        "_link_exports": attr.label(
            default = "//dart/private/tools:link_exports",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
        "_link_hook_runner": attr.label(
            default = "//dart/private/tools:link_hook_runner",
            executable = True,
            cfg = config.exec(PORTABLE),
        ),
    }

# What an unlinked program's assets need in `toolchains`: the C++ toolchain
# links a package's `linked_code_assets`, and is needed only by a program with
# one.
UNLINKED_PROGRAM_ASSETS_TOOLCHAINS = use_cc_toolchain(mandatory = False)

# What a rule calling `dart_program_assets_actions` declares in `toolchains`.
PROGRAM_ASSETS_TOOLCHAINS = COPY_TO_DIRECTORY_TOOLCHAINS + UNLINKED_PROGRAM_ASSETS_TOOLCHAINS

def vm_code_config(ctx):
    """Upstream's code-asset configuration of a Dart VM program for the target platform.

    Args:
      ctx: The rule context, with `program_assets_attrs()`.

    Returns:
      The `config.extensions.code_assets` object of a hook input.
    """
    os, _, architecture = target_dart_abi(ctx).partition("_")
    return {
        "link_mode_preference": "dynamic",
        "target_architecture": architecture,
        "target_os": os,
    }

def dart_program_assets_actions(ctx, package, deps, name, recorded_uses = None, code_config = None, code_assets = []):
    """What a program ships; the operation `dart_program_assets` performs.

    For a rule that bundles a program itself, or compiles its own kernel and
    so cannot depend on a `dart_program_assets` target without a cycle.
    Linking runs each package's link hook, which reads uses and writes data
    files, the same whichever host runs it, so the hooks run in `PORTABLE`:
    the caller's rule declares `PORTABLE_EXEC_GROUPS`, merges
    `program_assets_attrs()` into its `attrs`, and declares
    `PROGRAM_ASSETS_TOOLCHAINS` in its `toolchains` and `fragments = ["cpp"]`,
    with which it links a package's `linked_code_assets`.

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
      code_config: Linked, what every link hook is told of a target that
        loads code assets, as upstream's hook input has it at
        `config.extensions.code_assets` (`target_os`, `target_architecture`,
        `link_mode_preference`, and `ios` or `android` for those targets):
        `vm_code_config(ctx)` for a Dart VM program. `None` for a target that
        loads none (the web), whose packages with a link hook may declare
        none.
      code_assets: The program's own `DartCodeAssetInfo`, which ship as they
        are and replace any of its packages' under the same id: how a test
        loads a differently built library under the id a package declares.

    Returns:
      A struct: `info` (the program's `DartProgramAssetsInfo`) and
      `validation_outputs` (Files to put in an `_validation` output group, so
      that every link hook runs whenever the target builds, whatever its
      consumers read). What a kernel of the program maps is
      `program_kernel_code_assets(info)`.
    """
    packages = program_packages(package, deps)
    data_assets, err = unique_data_assets(packages)
    if err != None:
        fail("%s: %s" % (ctx.label, err))
    own_code = resolve_code_assets(ctx.label, [], code_assets)
    replaced = {a.asset_id: True for a in own_code}
    code_assets = resolve_code_assets(
        ctx.label,
        [asset for pkg in packages for asset in package_code_assets(pkg) if asset.asset_id not in replaced],
        [],
    )
    hooked = {}
    if recorded_uses != None:
        hooked = {pkg.package_name: pkg for pkg in packages if package_link_hook(pkg) != None}

    # The assets of packages without a link hook ship as they are, and are
    # known now; those of a package with one are its hook's input. The native
    # code a package links into each program is linked now, for this program.
    shipped_data = {a.id: a.file for a in data_assets if a.package not in hooked}
    shipped_code = [a for a in code_assets if _asset_package(a.asset_id) not in hooked]
    shipped_code += [
        _native_link(ctx, pkg, linked, recorded_uses, name)
        for pkg in packages
        for linked in package_linked_code_assets(pkg)
        if linked.asset_id not in replaced
    ] + own_code
    shipped_code = {a.asset_id: a for a in shipped_code}
    if not hooked:
        return struct(
            info = DartProgramAssetsInfo(data_assets = shipped_data, code_assets = shipped_code, link_outputs = ()),
            validation_outputs = [],
        )

    linked = _link_hook_actions(
        ctx,
        packages = packages,
        package = package,
        hooked = hooked,
        data_assets = data_assets,
        code_assets = code_assets,
        code_config = code_config,
        deps = deps,
        recorded_uses = recorded_uses,
        name = name,
    )
    shipped_data.update(linked.promised)
    return struct(
        info = DartProgramAssetsInfo(
            data_assets = shipped_data,
            code_assets = shipped_code,
            link_outputs = linked.outputs,
        ),
        # Each hook's output directory, which it always writes: a hook that
        # promises nothing still runs, and its verdict on the program is
        # never skipped.
        validation_outputs = [output.data_assets for output in linked.outputs],
    )

def _asset_package(asset_id):
    return asset_id[len("package:"):].partition("/")[0]

def _link_format(ctx):
    """How the target's linker names the symbols a shared library exports."""
    if ctx.target_platform_has_constraint(ctx.attr._os_windows[platform_common.ConstraintValueInfo]):
        return "def", "%s.dll"
    for os in ["_os_macos", "_os_ios"]:
        if ctx.target_platform_has_constraint(getattr(ctx.attr, os)[platform_common.ConstraintValueInfo]):
            return "macho", "lib%s.dylib"
    return "elf", "lib%s.so"

def _native_link(ctx, pkg, linked, recorded_uses, name):
    """Links one package's `linked_code_assets` entry for this program.

    Linked, its tool maps the program's uses to the symbols to keep, and the
    library exports just those, the rest of its code dropped as the linker
    can, as upstream's `LinkerOptions.treeshake` links it: an ELF version
    script with `--gc-sections`, a Mach-O exported-symbols list with
    `-dead_strip`, or a Windows module-definition file. Unlinked, it exports
    everything, as a build hook's library does: on Windows, through a
    module-definition file listing every symbol its own objects define, as
    `cc_binary` writes one under `windows_export_all_symbols`. A Windows DLL is
    always linked with a module-definition file, which makes the linker write
    the import library Bazel declares beside it even when nothing is exported.

    Returns:
      The program's `DartCodeAssetInfo` for it.
    """
    what = "%s: package `%s` links native code into each program (`%s`)" % (ctx.label, pkg.package_name, linked.asset_id)
    cc_toolchain = find_cc_toolchain(ctx, mandatory = False)
    if cc_toolchain == None:
        fail(what + ", and no C++ toolchain is registered for the target platform.")
    link_format, library_name = _link_format(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    prefix = "%s/%s/%s" % (name, pkg.package_name, linked.name)

    # The library's own objects are linked whole, as a `cc_shared_library`'s
    # `deps` are; what it depends on, as the link needs.
    linker_inputs = []
    objects = []
    for linker_input in linked.library.linking_context.linker_inputs.to_list():
        if linker_input.owner == linked.owner:
            for library_to_link in linker_input.libraries:
                if library_to_link.pic_static_library != None:
                    objects.extend(library_to_link.pic_objects or [])
                elif library_to_link.static_library != None:
                    objects.extend(library_to_link.objects or [])
            linker_input = cc_common.create_linker_input(
                owner = linker_input.owner,
                libraries = depset([
                    cc_common.create_library_to_link(
                        actions = ctx.actions,
                        feature_configuration = feature_configuration,
                        cc_toolchain = cc_toolchain,
                        static_library = library.static_library,
                        pic_static_library = library.pic_static_library,
                        alwayslink = True,
                    )
                    for library in linker_input.libraries
                    if library.static_library != None or library.pic_static_library != None
                ]),
                user_link_flags = linker_input.user_link_flags,
                additional_inputs = depset(linker_input.additional_inputs),
            )
        linker_inputs.append(linker_input)

    library = ctx.actions.declare_file("%s/%s/%s" % (name, pkg.package_name, library_name % linked.name))
    user_link_flags = []
    additional_inputs = []
    variables = {}
    if recorded_uses == None and link_format == "def":
        exports = _windows_export_all(ctx, cc_toolchain, feature_configuration, objects, library, prefix)
        additional_inputs.append(exports)
        variables["def_file_path"] = exports.path
    elif recorded_uses != None:
        symbols = ctx.actions.declare_file(prefix + ".symbols")
        args = ctx.actions.args()
        args.add(recorded_uses.file)
        args.add(symbols)
        ctx.actions.run(
            executable = linked.symbols,
            arguments = [args],
            inputs = [recorded_uses.file],
            outputs = [symbols],
            mnemonic = "DartLinkSymbols",
            progress_message = "Choosing the symbols of %s to keep for %s" % (linked.asset_id, ctx.label),
            # The package's own tool, from its `dart_linked_code_asset`: not
            # a toolchain's.
            toolchain = None,
        )
        exports = ctx.actions.declare_file(prefix + "." + link_format)
        args = ctx.actions.args()
        args.add("--format", link_format)
        args.add("--symbols", symbols)
        args.add("--output", exports)
        args.add("--tool", str(linked.symbols.executable.owner))
        ctx.actions.run(
            executable = ctx.executable._link_exports,
            arguments = [args],
            inputs = [symbols],
            outputs = [exports],
            mnemonic = "DartLinkExports",
            exec_group = PORTABLE,
            progress_message = "Listing the exports of %s for %s" % (linked.asset_id, ctx.label),
            execution_requirements = PATH_MAPPING,
        )
        additional_inputs.append(exports)
        if link_format == "elf":
            user_link_flags = ["-Wl,--version-script=" + exports.path, "-Wl,--gc-sections"]
        elif link_format == "macho":
            user_link_flags = ["-Wl,-exported_symbols_list," + exports.path, "-Wl,-dead_strip"]
        else:
            variables["def_file_path"] = exports.path
            user_link_flags = ["/OPT:REF"]
    cc_common.link(
        actions = ctx.actions,
        name = prefix,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        linking_contexts = [cc_common.create_linking_context(linker_inputs = depset(linker_inputs))],
        output_type = "dynamic_library",
        main_output = library,
        user_link_flags = user_link_flags,
        additional_inputs = additional_inputs,
        variables_extension = variables,
    )
    return DartCodeAssetInfo(
        asset_id = linked.asset_id,
        link_mode = "dynamic_loading_bundle",
        file = library,
        uri = "",
    )

def _windows_export_all(ctx, cc_toolchain, feature_configuration, objects, library, prefix):
    """Writes the module-definition file exporting every symbol `objects` define.

    As `cc_binary` writes one under `windows_export_all_symbols`: with the
    toolchain's `generate-def-file` action if it has one, else Bazel's DEF
    parser.

    Returns:
      The module-definition file.
    """
    exports = ctx.actions.declare_file(prefix + ".all.def")
    args = ctx.actions.args()
    args.add(exports)
    args.add(library.basename)
    objects_args = ctx.actions.args()
    objects_args.use_param_file("@%s", use_always = True)
    objects_args.set_param_file_format("shell")
    objects_args.add_all(objects)
    action = ACTION_NAMES.generate_def_file
    if cc_common.action_is_enabled(feature_configuration = feature_configuration, action_name = action):
        executable = cc_common.get_tool_for_action(feature_configuration = feature_configuration, action_name = action)
        inputs = depset(objects, transitive = [cc_toolchain.all_files])
        env = cc_common.get_environment_variables(
            feature_configuration = feature_configuration,
            action_name = action,
            variables = cc_common.empty_variables(),
        )
        execution_requirements = {
            requirement: ""
            for requirement in cc_common.get_execution_requirements(feature_configuration = feature_configuration, action_name = action)
        }
        toolchain = CC_TOOLCHAIN_TYPE
    else:
        executable = ctx.file._def_parser
        inputs = objects
        env = {}
        execution_requirements = {}
        toolchain = None
    ctx.actions.run(
        executable = executable,
        arguments = [args, objects_args],
        inputs = inputs,
        outputs = [exports],
        env = env,
        execution_requirements = execution_requirements,
        use_default_shell_env = True,
        mnemonic = "DefParser",
        progress_message = "Listing every symbol %s exports" % library.short_path,
        toolchain = toolchain,
    )
    return exports

def _link_hook_actions(ctx, packages, package, hooked, data_assets, code_assets, code_config, deps, recorded_uses, name):
    """Runs the link hook of each package in `hooked` over the program's uses.

    Returns:
      A struct: `outputs` (a `DartProgramAssetsInfo.link_outputs` entry per
      package, by package name) and `promised` (the File of each id a hook
      promises, by id).
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

    outputs = []
    promised_files = {}
    for package_name in sorted(hooked.keys()):
        pkg = hooked[package_name]

        # Checked where the record was built; parsed here for the names.
        promised, err = parse_data_asset_ids(pkg.label, package_link_hook_assets(pkg))
        if err != None:
            fail(err)
        root = roots[hook_keys[package_name]]
        directory = ctx.actions.declare_directory("%s/%s.data" % (name, package_name))
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
        args.add_all("--directory", [directory], expand_directories = False)
        inputs = [a for a in data_assets if a.package == package_name]
        for asset in inputs:
            args.add("--input-data-asset", asset.file, format = format_literal(asset.name) + "=%s")

        # A build hook routes its code assets to its link hook too, which
        # keeps some of them as they are declared.
        code_inputs = [a for a in code_assets if _asset_package(a.asset_id) == package_name]
        if code_config != None:
            args.add("--code-config", json.encode(code_config))
        elif code_inputs:
            fail(("%s: package `%s` has a `link_hook` and declares code assets %s, " +
                  "and the program's target loads none.") % (
                ctx.label,
                package_name,
                [a.asset_id for a in code_inputs],
            ))
        for asset in code_inputs:
            prefix = "%s=%s=" % (asset.asset_id, asset.link_mode)
            if asset.file != None:
                args.add("--input-code-asset", asset.file, format = format_literal(prefix) + "%s")
            else:
                args.add("--input-code-asset", prefix + asset.uri)
        hook_outputs = [directory]
        selection = None
        if code_inputs:
            selection = ctx.actions.declare_file("%s/%s.code_selection" % (name, package_name))
            hook_outputs.append(selection)
            args.add("--code-selection", selection)
        for asset in promised:
            out = ctx.actions.declare_file("%s/%s/%s" % (name, package_name, asset.name))
            hook_outputs.append(out)
            promised_files[asset.id] = out
            args.add("--promised-data-asset", out, format = format_literal(asset.name) + "=%s")
        outputs.append(struct(
            package = package_name,
            data_assets = directory,
            code_assets = {a.asset_id: a for a in code_inputs},
            code_selection = selection,
        ))
        ctx.actions.run(
            executable = ctx.executable._link_hook_runner,
            arguments = [args],
            inputs = depset(
                [recorded_uses.file] + package_inputs + [a.file for a in inputs] +
                [a.file for a in code_inputs if a.file != None],
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
    return struct(outputs = tuple(outputs), promised = promised_files)

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
    recorded_uses = _recorded_uses(ctx, package)
    result = dart_program_assets_actions(
        ctx,
        package = package,
        deps = ctx.attr.deps,
        name = ctx.label.name,
        recorded_uses = recorded_uses,
        code_config = vm_code_config(ctx) if recorded_uses != None else None,
    )

    # The program's assets in the line format with runfiles paths, for a test
    # or a program that has this target in its `data` to read with
    # `ProgramAssets.read`.
    listing = ctx.actions.declare_file(ctx.label.name + ".program_assets")
    ctx.actions.write(output = listing, content = _runfiles_lines(ctx, result.info))
    return [
        DefaultInfo(
            files = depset([listing]),
            runfiles = ctx.runfiles(files = [listing], transitive_files = program_assets_files(result.info)),
        ),
        result.info,
        # A hook that promises nothing has outputs only a consumer reads. As
        # a validation output that still runs whenever this target is built,
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
    fragments = ["cpp"],
    doc = """The assets a program ships, as `DartProgramAssetsInfo`: its packages' data and code \
assets, after their link hooks over the program's recorded uses when `recorded_uses` is set.

Its output, `<name>.program_assets`, lists them in the program-assets line format with runfiles \
paths, and its runfiles hold every file it names: a test or program with this target in its `data` \
reads it with `ProgramAssets.read` from `@rules_dart//dart/program_assets`.""",
)
