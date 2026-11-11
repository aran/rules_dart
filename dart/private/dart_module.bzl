"""Per-library kernel compilation: `dart_module_aspect`, and the entry and link steps.

An executable that compiled its whole program from source would compile a
library shared by many tests once per test. This is Dart's own modular
build (`build_modules`), in Bazel's terms:

  * Each `DartInfo` target's own sources are split as `build_modules`' fine
    strategy splits a package — one module per strongly connected component of
    their imports, with conditional imports decided for the platform — and
    every module is compiled once per configuration by `kernel_worker`, the
    SDK's front end built for Bazel. (Its coarse strategy merges private
    libraries into the public library that reaches them, which makes them
    unusable wherever that library is.)
  * A module that needs a `dart:` library the platform lacks, or that does
    not compile, is recorded rather than fatal: `build_modules` builds a
    module only when something reaches it, and Bazel, whose actions are fixed
    before any runs, gets the same answer by compiling all of a target's
    modules in one action and failing only an executable that reaches a
    broken one. A whole-program compile never read what nothing reached.
  * An executable compiles a generated entrypoint with `frontend_server`
    (the module compiler never records a `main`) against the modules it
    reaches, and links exactly those: concatenated kernel files are one
    program.

What Bazel adds to `build_modules` is its own discipline about dependencies:
a library importing a package none of its `deps` provide fails at that
library, and, unless the `dart_layering_check` feature is off, so does one
importing a package only a dependency's dependency provides.

Sources are read through `KERNEL_FILESYSTEM_SCHEME` with the exec root and the
output directories as roots, so a package whose files are split between the
source tree and `bazel-out` (generated parts) resolves without copying it into
one directory, and no absolute path reaches the output.

The aspect is a factory over `DartKernelSdkInfo` because a module is only valid
for the platform it was compiled against: rules_flutter makes its own with the
Flutter SDK and gets its own modules, and everything else here is shared.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartInfo", "DartKernelSdkInfo", "DartModuleInfo")
load("//dart/private:build_settings.bzl", "MODULAR_KERNEL_ATTR", "modular_kernel", "module_define_comma_error", "track_creation_locations", "validate_dart_defines")
load("//dart/private:common.bzl", "KERNEL_FILESYSTEM_SCHEME", "PATH_MAPPING", "VM_SANITIZER_DEFINES", "add_kernel_roots", "bootstrap_kernel_action", "collect_transitive_srcs", "dart_kernel_action", "kernel_root_path", "own_packages")
load(
    "//dart/private:dart_deps.bzl",
    "direct_dart_deps",
    "exported_libraries",
    "forwarded_library",
    "propagated_attrs",
    "propagated_toolchains",
    "reached_targets",
)
load("//dart/private:exec_groups.bzl", "EXEC_TOOLS_TOOLCHAIN", "PORTABLE", "PORTABLE_EXEC_GROUPS")
load("//dart/private:resources.bzl", "kernel_resources")

visibility("//dart/...")

_KERNEL_TOOL = Label("//dart/private/tools:kernel_tool")

# Built for the host of the `portable` actions that run it; a rule merging this
# into its `attrs` declares `PORTABLE_EXEC_GROUPS`.
KERNEL_TOOL_ATTR = {
    "_kernel_tool": attr.label(default = _KERNEL_TOOL, executable = True, cfg = config.exec(PORTABLE)),
}

# What an executable's whole program compiles with: the VM, without the outline
# tool the modules use, which is itself a `dart_binary`.
PROGRAM_KERNEL_SDK_ATTR = {
    "_program_kernel_sdk": attr.label(
        default = Label("//dart/private:vm_program_kernel_sdk"),
        providers = [DartKernelSdkInfo],
        cfg = config.exec(PORTABLE),
    ),
}

def kernel_package_config(packages, scheme = KERNEL_FILESYSTEM_SCHEME):
    """`package_config.json` content addressing each package through the kernel roots.

    Args:
      packages: `DartPackageInfo` records, one per package name.
      scheme: The file-system scheme the compile reads its sources through.

    Returns:
      The file content.
    """
    entries = []
    for pkg in packages:
        root = kernel_root_path(pkg.package_root)
        lv = ""
        if pkg.language_version:
            lv = ', "languageVersion": "%s"' % pkg.language_version
        entries.append('    {"name": "%s", "rootUri": "%s:///%s", "packageUri": "lib/"%s}' % (
            pkg.package_name,
            scheme,
            root + "/" if root else "",
            lv,
        ))
    return '{\n  "configVersion": 2,\n  "packages": [\n%s\n  ]\n}\n' % ",\n".join(entries)

def dart_kernel_runtime(platform, defines = [], flags = []):
    """One kind of runtime a platform's kernels are compiled for: an entry of `DartKernelSdkInfo.runtimes`.

    Build entries with this rather than by hand, so a field added to them is a
    change here and in no caller.

    Args:
      platform: The platform `.dill` File a kernel for this runtime compiles
        against; the front end finds the SDK in its directory.
      defines: The environment declarations this runtime fixes, e.g.
        `dart.vm.product=true`.
      flags: Further front-end flags every whole-program compile for this
        runtime takes, e.g. `--delete-tostring-package-uri=dart:ui`.

    Returns:
      The entry.
    """
    return struct(platform = platform, defines = list(defines), flags = list(flags))

def dart_whole_program_kernel_action(
        ctx,
        kernel_sdk,
        runtime,
        main,
        srcs,
        packages,
        output_dill,
        entrypoint_uri = None,
        sources = [],
        filesystem_scheme = KERNEL_FILESYSTEM_SCHEME,
        defines = [],
        flags = [],
        native_assets = None,
        track_creation_locations = False,
        outputs = {},
        resource_set = kernel_resources):
    """Compiles a whole program from source into one kernel, for any platform.

    What `dart_binary` and `dart_test` compile with, given the VM's
    `DartKernelSdkInfo`; a rule set with its own platform (Flutter), or a user
    with an SDK of their own, passes theirs. Each source is read where it
    stands: the front end searches the exec root and each output directory,
    under `filesystem_scheme`, so generated and checked-in files of one
    directory resolve together and no path of the machine or the sandbox
    reaches the kernel: two output bases build the same bytes. It prints
    nothing when the compile succeeds and takes only the files it reads: the
    sources, the compiler and its runtime, and the one platform dill.

    Because the kernel names no path, `gen_snapshot --resolve-dwarf-paths`
    cannot be used on what it compiles to (see `dart_kernel_action`).

    The compile runs through the rule's `_kernel_tool` (`KERNEL_TOOL_ATTR`),
    in the `PORTABLE` execution group (`PORTABLE_EXEC_GROUPS`), and
    `kernel_sdk` is built for that group's host
    (`cfg = config.exec(PORTABLE)`).

    Args:
      ctx: The rule context.
      kernel_sdk: The platform's `DartKernelSdkInfo`.
      runtime: The entry of `kernel_sdk.runtimes` the kernel is for: its
        platform dill, declarations and flags.
      main: The entrypoint File.
      srcs: Depset of every source File the program reads besides `main`;
        `collect_transitive_srcs` gives what `deps` reach.
      packages: The `DartPackageInfo` records the program compiles against,
        one per name (`collect_packages`), and any of the caller's own.
      output_dill: The `.dill` File to produce.
      entrypoint_uri: The URI to compile as the root library: a `package:`
        URI, or one under `filesystem_scheme`. By default `main`'s path in the
        workspace under `filesystem_scheme`.
      sources: URIs of further libraries compiled into the program beside the
        entrypoint (`--source`), as `entrypoint_uri`; their files are among
        `srcs`.
      filesystem_scheme: The scheme sources are read through. Another
        compiler that reads the same files under the same scheme (a dev loop's,
        for hot reload) names their libraries as this kernel does.
      defines: Environment declarations beyond the runtime's; each becomes a
        `-D` flag.
      flags: Further `frontend_server` flags beyond the runtime's (`--aot`,
        `--tfa`, `--enable-experiment=...`).
      native_assets: Optional native assets mapping File, embedded in the
        kernel (`--native-assets`).
      track_creation_locations: Whether to pass `--track-creation-locations`.
      outputs: Further files the compiler writes, by the flag that names each
        (`{"--recorded-uses": file}`).
      resource_set: What the compile uses, for Bazel's local scheduler: a
        top-level function `(os, inputs_size) -> dict`, as `ctx.actions.run`
        takes it. The front end holds the whole program in memory, which grows
        with the program, so a caller compiling large ones states its own.
        The default declares one core and 600 MB.
    """
    package_config = ctx.actions.declare_file(output_dill.basename + ".package_config.json", sibling = output_dill)
    ctx.actions.write(package_config, kernel_package_config(packages, filesystem_scheme))
    dart_kernel_action(
        ctx = ctx,
        kernel_sdk = kernel_sdk,
        runtime = runtime,
        main = main,
        srcs = srcs,
        package_config = package_config,
        output_dill = output_dill,
        entrypoint_uri = entrypoint_uri,
        sources = sources,
        filesystem_scheme = filesystem_scheme,
        defines = defines,
        flags = flags,
        native_assets = native_assets,
        track_creation_locations = track_creation_locations,
        outputs = outputs,
        kernel_tool = ctx.executable._kernel_tool,
        resource_set = resource_set,
    )

def whole_program_kernel(ctx, main, packages, output_dill, defines = [], flags = [], native_assets_yaml = None, track_creation_locations = False):
    """Compiles a VM executable's whole program from source into one kernel.

    The program is the rule's `main`, its own `srcs`, and every source its
    `deps` reach, compiled for the VM by `dart_whole_program_kernel_action`.
    A rule without a `_kernel_tool` (`dart_tool_binary`, which builds
    `kernel_tool`) compiles with `bootstrap_kernel_action`.

    Args:
      ctx: The rule context; the rule has `main`, `srcs` and `deps`, and
        merges `PROGRAM_KERNEL_SDK_ATTR` with `KERNEL_TOOL_ATTR`, or neither.
      main: The entrypoint File: `ctx.file.main`, or one generated around it.
      packages: The `DartPackageInfo` records the program compiles against.
      output_dill: The `.dill` File to produce.
      defines: See `dart_whole_program_kernel_action`.
      flags: See `dart_whole_program_kernel_action`.
      native_assets_yaml: See `native_assets` of `dart_whole_program_kernel_action`.
      track_creation_locations: See `dart_whole_program_kernel_action`.
    """
    srcs = depset([ctx.file.main] + ctx.files.srcs, transitive = [collect_transitive_srcs(ctx.attr.deps)])
    if not hasattr(ctx.attr, "_kernel_tool"):
        if native_assets_yaml != None or track_creation_locations:
            fail("%s: a tool built without `kernel_tool` takes no code assets and does not track creation locations" % ctx.label)
        package_config = ctx.actions.declare_file(output_dill.basename + ".package_config.json", sibling = output_dill)
        ctx.actions.write(package_config, kernel_package_config(packages))
        bootstrap_kernel_action(ctx, main, srcs, package_config, output_dill, defines, flags)
        return
    dart_whole_program_kernel_action(
        ctx,
        kernel_sdk = ctx.attr._program_kernel_sdk[DartKernelSdkInfo],
        runtime = "product",
        main = main,
        srcs = srcs,
        packages = packages,
        output_dill = output_dill,
        defines = defines,
        flags = flags,
        native_assets = native_assets_yaml,
        track_creation_locations = track_creation_locations,
    )

_OUTLINES = ".outlines"

def _info_path(module):
    # A module directory's manifest, for the directory or its outlines.
    path = module.path
    if path.endswith(_OUTLINES):
        path = path[:-len(_OUTLINES)]
    return path + ".json"

def _add_deps(args, modules):
    args.add_all(modules, before_each = "--dep-modules", expand_directories = False)
    args.add_all(modules, before_each = "--dep-manifest", map_each = _info_path, expand_directories = False)

def _dirname(f):
    return f.dirname

def _snapshot_args(ctx, snapshot):
    args = ctx.actions.args()
    args.add("--snapshot", snapshot)
    return args

def _new_args(ctx):
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    return args

def module_defines(ctx):
    """The environment declarations a module compiles with, in the aspect.

    An executable's own `defines`, and those it derives from its other
    attributes, reach its dependencies' modules through the transition of
    `executable_defines_config`, so its libraries are compiled (and cached) per
    set of declarations; the command-line flag comes last and wins, as it does
    for the executable itself.

    Args:
      ctx: A context carrying `_module_defines` and `_extra_dart_defines`.

    Returns:
      The list of `KEY=VALUE` strings.
    """
    return ctx.attr._module_defines[BuildSettingInfo].value + ctx.attr._extra_dart_defines[BuildSettingInfo].value

def _module_aspect_impl(target, ctx):
    # The build-wide escape hatch: executables compile whole programs, and
    # nothing reads a module.
    defines = module_defines(ctx)
    if not modular_kernel(ctx):
        return [DartModuleInfo(modules = depset(), outlines = depset(), manifests = depset(), exported = {}, defines = defines)]
    reached = reached_targets(ctx, DartModuleInfo)

    # Not a library: hand on the libraries it holds (a toolchain's runtime),
    # one hop, for the library that names them in its `DartInfo.deps`.
    if DartInfo not in target:
        return [DartModuleInfo(modules = depset(), outlines = depset(), manifests = depset(), exported = exported_libraries(reached), defines = defines)]
    info = target[DartInfo]

    # A target that passes on a dependency's `DartInfo` (`dart_test_package`
    # handing on `package:test`'s library) passes on its modules too, rather
    # than compiling the same files a second time.
    forwarded = forwarded_library(info, reached)
    if forwarded != None:
        return [forwarded[DartModuleInfo]]
    direct = direct_dart_deps(ctx, info, reached, DartModuleInfo)
    modules = _merge_modules([dep[DartModuleInfo] for dep in direct])

    # `getattr`: a provider built before `srcs` existed carries none, and
    # contributes no modules rather than failing.
    srcs = [f for f in getattr(info, "srcs", []) if f.is_directory or f.extension == "dart"]
    if not srcs:
        return [DartModuleInfo(modules = modules.modules, outlines = modules.outlines, manifests = modules.manifests, defines = defines)]

    # Only the target's own packages: its dependencies are read from their
    # modules, which name every library they hold.
    own = own_packages(info)
    return [_compile_modules(
        ctx,
        sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo],
        kernel_tool = ctx.executable._kernel_tool,
        name = ctx.label.name,
        srcs = srcs,
        packages = own,
        own_packages = own,
        modules = modules,
        defines = defines,
        track_creation_locations = track_creation_locations(ctx),
    )]

def _merge_modules(infos):
    return struct(
        modules = depset(transitive = [i.modules for i in infos], order = "postorder"),
        outlines = depset(transitive = [i.outlines for i in infos], order = "postorder"),
        manifests = depset(transitive = [i.manifests for i in infos], order = "postorder"),
    )

def _check_no_comma(define, source):
    err = module_define_comma_error(define, source)
    if err:
        fail(err)

def _compile_modules(ctx, sdk, kernel_tool, name, srcs, packages, own_packages, modules, defines, track_creation_locations):
    """Compiles `srcs` into kernel modules against `modules`.

    The sources are split as Dart's own modular build splits a package, finely:
    one module per strongly connected component of their imports on this
    platform. Each compiles once, here; a
    module that needs a `dart:` library the platform lacks, or does not
    compile, is recorded in the manifest and fails only an executable that
    reaches it — a whole-program compile never read what nothing reached.

    Args:
      ctx: The rule or aspect context.
      sdk: The `DartKernelSdkInfo`.
      kernel_tool: The `kernel_tool` executable.
      name: Basename for the outputs, unique in the package.
      srcs: The Dart sources (or source directories) to compile.
      packages: `DartPackageInfo` records for the package config: those whose
        language version the sources take.
      own_packages: The `DartPackageInfo` records the sources belong to: one,
        none for an executable stating no package, several for packages that
        depend on each other.
      modules: `struct(modules, outlines, manifests)` of every dependency's
        modules; the sources compile against the outlines.
      defines: Environment declarations beyond the platform's.
      track_creation_locations: Whether to compile with
        `--track-creation-locations`.

    Returns:
      `DartModuleInfo` of the new modules and `modules`.
    """
    if sdk.kernel_worker == None or sdk.libraries_spec == None:
        fail("%s: the `%s` platform's DartKernelSdkInfo has no `kernel_worker` or `libraries_spec`, so it compiles whole programs only, not modules" % (ctx.label, sdk.target))
    base = "%s.%s" % (name, sdk.target)
    out = ctx.actions.declare_directory(base + ".modules")
    manifest = ctx.actions.declare_file(out.basename + ".json", sibling = out)
    package_config = ctx.actions.declare_file(base + ".module_package_config.json")
    ctx.actions.write(package_config, kernel_package_config(packages))

    args = _new_args(ctx)
    args.add("--label", str(ctx.label))
    _add_sdk_args(args, sdk)
    args.add("--libraries-spec", sdk.libraries_spec)
    args.add("--libraries-target", sdk.libraries_target)
    args.add("--package-config", package_config)
    for own in own_packages:
        args.add("--package-name", own.package_name)
        args.add("--package-root", own.package_root)
    add_kernel_roots(args, "--multi-root", srcs)
    args.add_all(srcs, before_each = "--src", expand_directories = False)
    _add_deps(args, modules.outlines)
    args.add_all(module_runtime(sdk).defines + defines, before_each = "--define")
    if track_creation_locations:
        args.add("--track-creation-locations")
    args.add_all([out], before_each = "--output-dir", expand_directories = False)
    args.add("--manifest-output", manifest)

    # Dependents compile against the modules' outlines, which an edit inside a
    # function body leaves as they were, so Bazel reuses their compiles.
    outlines = out
    outputs = [out, manifest]
    tools = [sdk.kernel_worker, sdk.aot_runtime]
    outline_tool = getattr(sdk, "outline_tool", None)
    if outline_tool != None:
        outlines = ctx.actions.declare_directory(out.basename + _OUTLINES, sibling = out)
        outputs.append(outlines)
        tools.append(outline_tool)
        args.add("--outline-tool", outline_tool.executable)
        args.add_all([outlines], before_each = "--outline-dir", expand_directories = False)

    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["module", _snapshot_args(ctx, sdk.kernel_worker), args],
        inputs = depset(
            srcs + [package_config, sdk.libraries_spec, module_runtime(sdk).platform, sdk.kernel_worker, sdk.aot_runtime],
            transitive = [modules.outlines, modules.manifests, sdk.tool_files],
        ),
        # The SDK's compiler is a tool, so that a different one (a new SDK, a
        # different snapshot) is a different worker, not the old one reused.
        tools = tools,
        outputs = outputs,
        mnemonic = "DartModule",
        exec_group = PORTABLE,
        progress_message = "Compiling Dart modules %{label}",
        # `kernel_tool` keeps one `kernel_worker` running across targets, and
        # shows each request's compiler only that request's declared sources.
        # The last argument is the params file Bazel requires of a worker.
        execution_requirements = PATH_MAPPING | {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )
    return DartModuleInfo(
        modules = depset([out], transitive = [modules.modules], order = "postorder"),
        outlines = depset([outlines], transitive = [modules.outlines], order = "postorder"),
        manifests = depset([manifest], transitive = [modules.manifests], order = "postorder"),
        defines = defines,
    )

def _add_sdk_args(args, sdk):
    args.add("--runtime", sdk.aot_runtime)
    args.add("--platform", module_runtime(sdk).platform)
    args.add("--target", sdk.target)

def module_runtime(sdk):
    """The runtime of a `DartKernelSdkInfo` modules compile for.

    Args:
      sdk: The `DartKernelSdkInfo`.

    Returns:
      Its `runtimes` entry named by `module_runtime`.
    """
    runtime = sdk.runtimes.get(sdk.module_runtime)
    if runtime == None:
        fail("DartKernelSdkInfo for `%s`: `module_runtime` %r names none of its runtimes (%s)" % (
            sdk.target,
            sdk.module_runtime,
            ", ".join(sorted(sdk.runtimes)),
        ))
    return runtime

def dart_module_aspect(
        kernel_sdk,
        extra_dart_defines = Label("//dart:extra_dart_defines"),
        exec_toolchains = [],
        track_creation_locations = Label("//dart:track_creation_locations")):
    """Makes the aspect that compiles every `DartInfo` target to a kernel module.

    Call it at the top level of a `.bzl` file and assign the result, once per
    platform; rules_dart's own is `vm_module_aspect`. Attach it to an
    executable's `deps` (`attr.label_list(aspects = [...])`), compile the
    entrypoint against `DartModuleInfo.modules`, and link with
    `dart_link_kernel_action`.

    The modules compile in `PORTABLE`, and `kernel_sdk` is built for the host
    that group resolves to.

    Args:
      kernel_sdk: Label of a target providing `DartKernelSdkInfo`.
      extra_dart_defines: The command-line defines flag the executables read,
        so a dependency's module folds the same declarations as the
        entrypoint compiled against it.
      exec_toolchains: Toolchain types `kernel_sdk` resolves besides the Dart
        SDK, so the modules compile only on a host that has them.
      track_creation_locations: The flag that turns on the front end's
        creation-location transform, which the executables read too: every
        module and the entrypoint compile with the same setting.

    Returns:
      The aspect.
    """
    return aspect(
        implementation = _module_aspect_impl,
        attr_aspects = propagated_attrs,
        toolchains_aspects = propagated_toolchains,
        exec_groups = {
            PORTABLE: exec_group(toolchains = [EXEC_TOOLS_TOOLCHAIN] + exec_toolchains),
        } if exec_toolchains else PORTABLE_EXEC_GROUPS,
        attrs = KERNEL_TOOL_ATTR | MODULAR_KERNEL_ATTR | {
            "_kernel_sdk": _kernel_sdk_attr(kernel_sdk),
            "_extra_dart_defines": attr.label(default = extra_dart_defines),
            "_track_creation_locations": attr.label(default = track_creation_locations),
            "_module_defines": attr.label(default = Label("//dart/private:module_defines")),
        },
    )

def _kernel_sdk_attr(kernel_sdk):
    # Built for the host the modules compile on: the front end runs there.
    return attr.label(default = kernel_sdk, providers = [DartKernelSdkInfo], cfg = config.exec(PORTABLE))

vm_module_aspect = dart_module_aspect(Label("//dart/private:vm_kernel_sdk"))

_MODULE_DEFINES_SETTING = Label("//dart/private:module_defines")
_MODULE_DEFINES = str(_MODULE_DEFINES_SETTING)

def _check_defines(defines, source):
    validate_dart_defines(defines, source)
    for define in defines:
        _check_no_comma(define, source)

def _executable_environment(attrs, implied_defines):
    """An executable's `defines`, then those `implied_defines` derives from it.

    Checked by `executable_defines`, in the rule, where a failure names the
    target and an analysis test can see it.
    """
    own = list(attrs.defines)
    if implied_defines == None:
        return own
    implied = implied_defines(attrs)
    if type(implied) != "list":
        fail("%s, for `%s`, must return a list of `KEY=VALUE` strings, not %r" % (implied_defines, attrs.name, implied))
    return own + implied

def executable_defines_config(implied_defines = None):
    """Makes the environment an executable and its dependencies' modules compile in.

    The environment is the executable's `defines`, then what `implied_defines`
    derives from its attributes, then the command-line flag
    (`_extra_dart_defines`). It reaches the dependencies' modules as
    configuration: `cfg` is the transition for each attribute whose
    dependencies are compiled into modules (`deps`, through the module
    aspect), and `attrs` reads the same configuration back for the executable
    itself, which `dart_entry_kernel_action` and `executable_defines` use. So a
    declaration reaches both or neither: the entry compile also fails if its
    dependencies' modules were compiled in any other.

    Call it at the top level of a `.bzl` file and assign the result, once per
    rule kind. The rule has a `defines` attribute and an `_extra_dart_defines`
    one naming the same flag as its module aspect's.

    Args:
      implied_defines: A function of the executable's attributes (a
        transition's `attr`) returning the `KEY=VALUE` declarations they imply,
        appended after `defines`; or `None`. A key it returns that `defines`
        sets too is an error.

    Returns:
      `struct(cfg, attrs)`: `cfg` the transition, and `attrs` to merge into
      the rule's attributes.
    """

    def _transition_impl(_settings, attrs):
        return {_MODULE_DEFINES: _executable_environment(attrs, implied_defines)}

    cfg = transition(
        implementation = _transition_impl,
        inputs = [],
        outputs = [_MODULE_DEFINES],
    )
    return struct(
        cfg = cfg,
        attrs = {
            "_module_defines": attr.label(
                doc = "The environment `cfg` carries to the dependencies' modules, read back for the executable.",
                default = _MODULE_DEFINES_SETTING,
                providers = [BuildSettingInfo],
                cfg = cfg,
            ),
        },
    )

def executable_defines(ctx):
    """The environment an executable made with `executable_defines_config` compiles in.

    The same as its dependencies' modules: for a compile of its own the rule
    runs, such as one of the whole program. `dart_entry_kernel_action` reads it
    itself. Fails on a declaration a module compile would mangle, or a key the
    rule derives that `defines` sets too, naming where it came from.

    Args:
      ctx: The rule context, with `executable_defines_config(...).attrs` and
        `_extra_dart_defines` among its attributes.

    Returns:
      The `KEY=VALUE` strings, the flag's last.
    """
    if not hasattr(ctx.attr, "_module_defines") or not hasattr(ctx.attr, "_extra_dart_defines"):
        fail("%s: the rule must merge `executable_defines_config(...).attrs` and an `_extra_dart_defines` attribute into its `attrs`" % ctx.label)

    # One target: a label attribute with a Starlark transition is a list.
    environment = ctx.attr._module_defines[0][BuildSettingInfo].value
    own = ctx.attr.defines
    implied = environment[len(own):]
    _check_defines(own, "the `defines` of %s" % ctx.label)
    _check_defines(implied, "the defines the rule of %s derives from its attributes" % ctx.label)
    own_keys = {d.partition("=")[0]: d for d in own}
    for define in implied:
        key = define.partition("=")[0]
        if key in own_keys:
            fail(("%s: `%s` is derived from the target's attributes, and its `defines` sets it too " +
                  "(`%s`). Remove it from `defines`.") % (ctx.label, define, own_keys[key]))
    flag = ctx.attr._extra_dart_defines
    for define in flag[BuildSettingInfo].value:
        _check_no_comma(define, "`--%s`, building %s" % (flag.label, ctx.label))
    return environment + flag[BuildSettingInfo].value

# What an executable needs to compile its entrypoint and link: its `deps`,
# through the module aspect and the defines transition, and the tools. The rule
# declares `PORTABLE_EXEC_GROUPS`, where those compiles run.
MODULE_EXECUTABLE_ATTRS = KERNEL_TOOL_ATTR | {
    "_kernel_sdk": _kernel_sdk_attr(Label("//dart/private:vm_kernel_sdk")),
}

def collect_modules(deps):
    """The modules and manifests of `deps`, dependencies first.

    Args:
      deps: Targets carrying `DartModuleInfo` (through the aspect).

    Returns:
      `struct(modules, outlines, manifests, defines)`: depsets, and the
      environment each dependency's modules were compiled in.
    """
    compiled = [dep for dep in deps if DartModuleInfo in dep]
    merged = _merge_modules([dep[DartModuleInfo] for dep in compiled])
    return struct(
        modules = merged.modules,
        outlines = merged.outlines,
        manifests = merged.manifests,
        # Only a dependency that holds modules has an environment they were
        # compiled in; one configured by `non_dart_transition` that holds none
        # (assets, say) cannot disagree.
        defines = [(dep.label, dep[DartModuleInfo].defines) for dep in compiled if dep[DartModuleInfo].modules],
    )

def _check_same_environment(ctx, modules, defines):
    for label, theirs in modules.defines:
        if theirs != defines:
            fail(("%s compiles its entrypoint with %s, but the modules of its dependency %s were " +
                  "compiled with %s. Every attribute whose dependencies are compiled into modules " +
                  "takes the `cfg` of the `executable_defines_config` whose `attrs` the rule merges, " +
                  "and the rule's `_extra_dart_defines` names the flag its module aspect reads.") %
                 (ctx.label, defines, label, theirs))

def _check_modular(ctx):
    # Under the escape hatch the aspect compiles no module, so an entrypoint
    # compiled against them would find none of its dependencies' sources.
    if not hasattr(ctx.attr, "_modular_kernel"):
        fail("%s: the rule must merge `MODULAR_KERNEL_ATTR` into its `attrs`, and compile its whole program with `dart_whole_program_kernel_action` when `modular_kernel(ctx)` is false" % ctx.label)
    if not modular_kernel(ctx):
        fail(("%s: `--@rules_dart//dart:modular_kernel` is off, so no module is compiled, and its rule compiles its " +
              "entrypoint against modules. A rule calling `dart_entry_kernel_action` compiles its whole program " +
              "from source with `dart_whole_program_kernel_action` when `modular_kernel(ctx)` is false.") % ctx.label)

def dart_entry_kernel_action(
        ctx,
        sdk,
        kernel_tool,
        main,
        srcs,
        packages,
        modules,
        output,
        own_package = None,
        native_assets_yaml = None,
        track_creation_locations = False):
    """Compiles an executable against the modules its entrypoint reaches.

    The executable's own files (`srcs`) are compiled into modules like any
    library's, keeping their line numbers. `main` — a
    generated entrypoint such as a test bootstrap — is compiled on its own by
    `frontend_server`, because that is what records the program's `main` and
    `kernel_worker` never does; `frontend_server` drops the source positions
    of whatever it compiles against modules, which costs only `main`'s own
    frames. Only the modules `main` reaches are compiled against and, by
    `dart_link_kernel_action`, linked; reaching one that is unsupported on the
    platform or did not compile fails here, with its errors.

    The rule merges `MODULAR_KERNEL_ATTR` into its `attrs`. Under the escape
    hatch, when `modular_kernel(ctx)` is false, no module is compiled: the
    rule compiles its whole program with `dart_whole_program_kernel_action`
    instead, and this fails if called.

    Args:
      ctx: The rule context.
      sdk: The `DartKernelSdkInfo`.
      kernel_tool: The `kernel_tool` executable.
      main: The generated entrypoint File.
      srcs: The executable's own source Files (its entrypoint among them).
      packages: Every `DartPackageInfo` the executable sees, one per name, so
        its files get the language version of the package containing them.
      modules: `struct(modules, outlines, manifests, defines)` from
        `collect_modules`.
      output: The entry `.dill` to write.
      own_package: The `DartPackageInfo` of the package the executable states
        it belongs to, or `None`.
      native_assets_yaml: Optional `native_assets.yaml` to embed.
      track_creation_locations: Whether to compile with
        `--track-creation-locations`; the same as the modules were.

    Returns:
      `struct(modules, manifests, selection)`: every module the executable
      sees, its own included, and the File naming those `main` reaches, to
      link with the entry.
    """

    _check_modular(ctx)

    # The environment is the rule's configuration, not an argument, so that
    # the entrypoint cannot be compiled in another than its modules.
    defines = executable_defines(ctx)
    _check_same_environment(ctx, modules, defines)
    own = _compile_modules(
        ctx,
        sdk = sdk,
        kernel_tool = kernel_tool,
        name = ctx.label.name + ".own",
        srcs = srcs,
        packages = packages,
        own_packages = [own_package] if own_package != None else [],
        modules = modules,
        defines = defines,
        track_creation_locations = track_creation_locations,
    )

    package_config = ctx.actions.declare_file(output.basename + ".package_config.json", sibling = output)
    ctx.actions.write(package_config, kernel_package_config(packages))
    selection = ctx.actions.declare_file(output.basename + ".selection.json", sibling = output)

    args = _new_args(ctx)
    args.add("--label", str(ctx.label))
    _add_sdk_args(args, sdk)
    args.add_all([module_runtime(sdk).platform], before_each = "--sdk-root", map_each = _dirname)
    args.add("--package-config", package_config)
    add_kernel_roots(args, "--multi-root", [main])
    _add_deps(args, own.outlines)
    args.add_all(module_runtime(sdk).defines + defines, before_each = "--define")
    if track_creation_locations:
        args.add("--track-creation-locations")
    inputs = [main, package_config, module_runtime(sdk).platform, sdk.frontend_server, sdk.aot_runtime]
    if native_assets_yaml != None:
        args.add("--native-assets", native_assets_yaml)
        inputs.append(native_assets_yaml)
    args.add("--main", main)
    args.add("--output", output)
    args.add("--selection-output", selection)

    # The module directories `main` reaches nothing in: a change to one cannot
    # change the entrypoint, and Bazel does not rerun it for one.
    unused = ctx.actions.declare_file(output.basename + ".unused_inputs", sibling = output)
    args.add("--unused-inputs-output", unused)

    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["entry", _snapshot_args(ctx, sdk.frontend_server), args],
        inputs = depset(inputs, transitive = [own.outlines, own.manifests, sdk.tool_files]),
        outputs = [output, selection, unused],
        unused_inputs_list = unused,
        mnemonic = "DartEntryKernel",
        exec_group = PORTABLE,
        progress_message = "Compiling Dart entrypoint %{label}",
        execution_requirements = PATH_MAPPING,
    )
    return struct(modules = own.modules, manifests = own.manifests, selection = selection)

def _short_path(f):
    return f.short_path

def dart_link_kernel_action(ctx, kernel_tool, entry, linked, output, kernel_list = False):
    """Links an entry `.dill` and the modules its entrypoint reaches into one program.

    Fails if one library is compiled into two of those modules: the front end
    would silently use one copy, and which one would depend on dependency
    order.

    As a kernel list, `output` is `#@dill` and then a line per kernel, the
    entry first, each the path from `output` to that kernel in the runfiles
    tree: the VM reads the list as the program they make together, so the
    kernels are stored once however many programs list them. They must be in
    the runfiles beside `output`, which is what this returns. A launcher whose
    runfiles may be a manifest, not a tree, resolves the lines through it
    (`@rules_dart//dart/kernel_list`).

    Args:
      ctx: The rule context.
      kernel_tool: The `kernel_tool` executable.
      entry: The entry `.dill`, from the platform's entrypoint compile.
      linked: `struct(modules, manifests, selection)` from
        `dart_entry_kernel_action`.
      output: The program `.dill` to write.
      kernel_list: Whether to write `output` as a kernel list rather than one
        joined kernel; `kernel_list(ctx)` for the build's choice.

    Returns:
      A depset of the files `output` names, for the runfiles beside it: empty
      for a joined kernel.
    """
    args = _new_args(ctx)
    args.add("--label", str(ctx.label))
    args.add("--selection", linked.selection)
    args.add_all(linked.modules, before_each = "--dep-manifest", map_each = _info_path, expand_directories = False)
    args.add("--output", output)
    if kernel_list:
        # Named by where they are in runfiles, which no configuration changes.
        args.add("--workspace-name", ctx.workspace_name)
        args.add("--list-short-path", output.short_path)
        args.add("--entry-short-path", entry.short_path)
        args.add_all(linked.modules, before_each = "--dep-short-path", map_each = _short_path, expand_directories = False)

        # The list is made from the selection and the manifests alone.
        inputs = depset([linked.selection], transitive = [linked.manifests])
        runfiles = depset([entry], transitive = [linked.modules])
    else:
        args.add("--entry", entry)
        inputs = depset([entry, linked.selection], transitive = [linked.modules, linked.manifests])
        runfiles = depset()
    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["link", args],
        inputs = inputs,
        outputs = [output],
        mnemonic = "DartLinkKernel",
        exec_group = PORTABLE,
        progress_message = "Linking Dart kernel %{label}",
        execution_requirements = PATH_MAPPING,
    )
    return runfiles

_OUTLINE_FLAG = "--@rules_dart//dart:outline_kernel=false"

def _vm_outline_tool(ctx, sdk):
    """The outline stripper of the outline toolchain, which must be of `sdk`'s version."""
    toolchain = ctx.toolchains["//dart:outline_toolchain_type"]
    if toolchain == None:
        fail("%s: no outline toolchain (`@rules_dart//dart:outline_toolchain_type`) is registered for the Dart %s SDK. Register a `dart_outline_toolchain` built on that SDK's `pkg/kernel`, or build with %s to compile dependents against full kernels." % (ctx.label, sdk.version, _OUTLINE_FLAG))
    if toolchain.outline_tool == None:
        fail("%s: the outline toolchain of the Dart %s SDK has no `tool`, though `--@rules_dart//dart:outline_kernel` is on. Set its `tool`, or build with %s." % (ctx.label, toolchain.version, _OUTLINE_FLAG))
    if toolchain.version != sdk.version:
        fail("%s: the outline toolchain is of the Dart %s SDK, but the Dart toolchain is %s: its stripper reads only the kernels of its own SDK. Register the outline toolchain of the Dart %s SDK with its Dart toolchain (`dart_outline_toolchain`), or build with %s." % (ctx.label, toolchain.version, sdk.version, sdk.version, _OUTLINE_FLAG))
    return toolchain.outline_tool

def _vm_kernel_sdk_impl(ctx):
    sdk = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info
    root = sdk.dart.dirname.rsplit("/", 1)[0]
    wanted = {
        "runtime": [root + "/bin/dartaotruntime", root + "/bin/dartaotruntime.exe"],
        "kernel_worker": [root + "/bin/snapshots/kernel_worker_aot.dart.snapshot"],
        "frontend_server": [root + "/bin/snapshots/frontend_server_aot.dart.snapshot"],
        "product_platform": [root + "/lib/_internal/vm_platform_product.dill"],
        "libraries_spec": [root + "/lib/libraries.json"],
    }
    found = {}

    # Once per configuration: a probe for five files in the SDK.
    for f in sdk.files.kernel.to_list():
        for key, paths in wanted.items():
            if f.path in paths:
                found[key] = f
    missing = [k for k in wanted if k not in found]
    if missing:
        fail("could not find %s in the Dart %s SDK at %s" % (", ".join(missing), sdk.version, root))
    return [DartKernelSdkInfo(
        target = "vm",
        aot_runtime = found["runtime"],
        kernel_worker = found["kernel_worker"],
        frontend_server = found["frontend_server"],
        # The platform `dart compile` chooses for the product runtime of an
        # AOT snapshot, an executable or a `dart compile kernel` file.
        runtimes = {
            "product": dart_kernel_runtime(found["product_platform"], defines = ["dart.vm.product=true"] + VM_SANITIZER_DEFINES),
        },
        # What `dart compile kernel` folds in: a product runtime.
        module_runtime = "product",
        libraries_spec = found["libraries_spec"],
        libraries_target = "vm",
        # The tools read the files named above and nothing else of the SDK.
        tool_files = depset(),
        outline_tool = _vm_outline_tool(ctx, sdk) if getattr(ctx.attr, "outlines", False) else None,
    )]

vm_kernel_sdk = rule(
    implementation = _vm_kernel_sdk_impl,
    toolchains = [
        "//dart:toolchain_type",
        # Resolved even with `outlines` off, when its `tool` is unset.
        config_common.toolchain_type("//dart:outline_toolchain_type", mandatory = False),
    ],
    attrs = {
        "outlines": attr.bool(doc = "Whether modules are stripped to outlines, with the outline toolchain's stripper: `--@rules_dart//dart:outline_kernel`."),
    },
    doc = "The `DartKernelSdkInfo` modules compile with for the Dart VM, from the resolved Dart toolchain and its outline toolchain.",
)

vm_program_kernel_sdk = rule(
    implementation = _vm_kernel_sdk_impl,
    toolchains = ["//dart:toolchain_type"],
    doc = "The `DartKernelSdkInfo` whole programs compile with for the Dart VM, from the resolved Dart toolchain. Outlines are the modules' alone.",
)
