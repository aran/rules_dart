"""Per-library kernel compilation: `dart_module_aspect`, and the entry and link steps.

An executable used to compile its whole program from source, so a library
shared by many tests was compiled once per test. This is Dart's own modular
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
load("//dart/private:build_settings.bzl", "vm_define_comma_error")
load("//dart/private:common.bzl", "KERNEL_FILESYSTEM_SCHEME", "PATH_MAPPING", "add_kernel_roots", "collect_transitive_srcs", "dart_kernel_action", "kernel_root_path", "own_package_record")
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

_KERNEL_TOOL = Label("//dart/private/tools:kernel_tool")

# Built for the host of the `portable` actions that run it; a rule merging this
# into its `attrs` declares `PORTABLE_EXEC_GROUPS`.
KERNEL_TOOL_ATTR = {
    "_kernel_tool": attr.label(default = _KERNEL_TOOL, executable = True, cfg = config.exec(PORTABLE)),
}

def kernel_package_config(packages):
    """`package_config.json` content addressing each package through the kernel roots.

    Args:
      packages: `DartPackageInfo` records, one per package name.

    Returns:
      The file content.
    """
    entries = []
    for pkg in packages:
        root = kernel_root_path(pkg.lib_root)
        lv = ""
        if getattr(pkg, "language_version", ""):
            lv = ', "languageVersion": "%s"' % pkg.language_version
        entries.append('    {"name": "%s", "rootUri": "%s:///%s", "packageUri": "lib/"%s}' % (
            pkg.package_name,
            KERNEL_FILESYSTEM_SCHEME,
            root + "/" if root else "",
            lv,
        ))
    return '{\n  "configVersion": 2,\n  "packages": [\n%s\n  ]\n}\n' % ",\n".join(entries)

def whole_program_kernel(ctx, main, packages, output_dill, product, defines = [], flags = [], native_assets_yaml = None):
    """Compiles an executable's whole program from source into one kernel.

    The program is the rule's `main`, its own `srcs`, and every source its
    `deps` reach. Each is read where it stands: the front end searches the exec
    root and each output directory (`dart_kernel_action`), so generated and
    checked-in files of one directory resolve together.

    Args:
      ctx: The rule context; the rule has `main`, `srcs` and `deps`.
      main: The entrypoint File: `ctx.file.main`, or one generated around it.
      packages: The `DartPackageInfo` records the program compiles against.
      output_dill: The `.dill` File to produce.
      product: See `dart_kernel_action`.
      defines: See `dart_kernel_action`.
      flags: See `dart_kernel_action`.
      native_assets_yaml: See `dart_kernel_action`.
    """
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(package_config, kernel_package_config(packages))
    dart_kernel_action(
        ctx = ctx,
        main = main,
        transitive_srcs = depset([ctx.file.main] + ctx.files.srcs, transitive = [collect_transitive_srcs(ctx.attr.deps)]),
        package_config = package_config,
        output_dill = output_dill,
        product = product,
        defines = defines,
        flags = flags,
        native_assets_yaml = native_assets_yaml,
    )

def _info_path(module):
    return module.path + ".json"

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
    """The environment declarations a module compiles with.

    A test's own `defines` reach its dependencies' modules through
    `module_defines_transition`, so its libraries are compiled (and cached) per
    set of declarations; the command-line flag comes last and wins, as it does
    for the test itself.

    Args:
      ctx: A context carrying `_module_defines` and `_extra_dart_defines`.

    Returns:
      The list of `KEY=VALUE` strings.
    """
    return ctx.attr._module_defines[BuildSettingInfo].value + ctx.attr._extra_dart_defines[BuildSettingInfo].value

def _module_aspect_impl(target, ctx):
    # The build-wide escape hatch: executables compile whole programs, and
    # nothing reads a module.
    if not ctx.attr._modular_kernel[BuildSettingInfo].value:
        return [DartModuleInfo(modules = depset(), manifests = depset(), exported = {})]
    reached = reached_targets(ctx, DartModuleInfo)

    # Not a library: hand on the libraries it holds (a toolchain's runtime),
    # one hop, for the library that names them in its `DartInfo.deps`.
    if DartInfo not in target:
        return [DartModuleInfo(modules = depset(), manifests = depset(), exported = exported_libraries(reached))]
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
        return [DartModuleInfo(modules = modules.modules, manifests = modules.manifests)]

    # Only the target's own package: its dependencies are read from their
    # modules, which name every library they hold.
    own = own_package_record(info)
    return [_compile_modules(
        ctx,
        sdk = ctx.attr._kernel_sdk[DartKernelSdkInfo],
        kernel_tool = ctx.executable._kernel_tool,
        name = ctx.label.name,
        srcs = srcs,
        packages = [own] if own else [],
        own_package = own,
        modules = modules,
        defines = module_defines(ctx),
    )]

def _merge_modules(infos):
    return struct(
        modules = depset(transitive = [i.modules for i in infos], order = "postorder"),
        manifests = depset(transitive = [i.manifests for i in infos], order = "postorder"),
    )

def _check_no_comma(define, source):
    err = vm_define_comma_error(define, source)
    if err:
        fail(err)

def _compile_modules(ctx, sdk, kernel_tool, name, srcs, packages, own_package, modules, defines):
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
      own_package: The `DartPackageInfo` the sources belong to, or `None`.
      modules: `struct(modules, manifests)` of every dependency's modules.
      defines: Environment declarations beyond the platform's.

    Returns:
      `DartModuleInfo` of the new modules and `modules`.
    """
    for define in defines:
        _check_no_comma(define, "the executable's `defines` or the extra defines flag")
    base = "%s.%s" % (name, sdk.target)
    out = ctx.actions.declare_directory(base + ".modules")
    manifest = ctx.actions.declare_file(out.basename + ".json")
    package_config = ctx.actions.declare_file(base + ".module_package_config.json")
    ctx.actions.write(package_config, kernel_package_config(packages))

    args = _new_args(ctx)
    args.add("--label", str(ctx.label))
    _add_sdk_args(args, sdk)
    args.add("--libraries-spec", sdk.libraries_spec)
    args.add("--libraries-target", sdk.libraries_target)
    args.add("--package-config", package_config)
    if own_package != None:
        args.add("--package-name", own_package.package_name)
        args.add("--lib-root", own_package.lib_root)
    add_kernel_roots(args, "--multi-root", srcs)
    args.add_all(srcs, before_each = "--src", expand_directories = False)
    _add_deps(args, modules.modules)
    args.add_all(sdk.defines + defines, before_each = "--define")
    args.add_all([out], before_each = "--output-dir", expand_directories = False)
    args.add("--manifest-output", manifest)

    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["module", _snapshot_args(ctx, sdk.kernel_worker), args],
        inputs = depset(
            srcs + [package_config, sdk.libraries_spec, sdk.platform, sdk.kernel_worker, sdk.runtime],
            transitive = [modules.modules, modules.manifests, sdk.tool_files],
        ),
        # The SDK's compiler is a tool, so that a different one (a new SDK, a
        # different snapshot) is a different worker, not the old one reused.
        tools = [sdk.kernel_worker, sdk.runtime],
        outputs = [out, manifest],
        mnemonic = "DartModule",
        exec_group = PORTABLE,
        progress_message = "Compiling Dart modules %{label}",
        # `kernel_tool` keeps one `kernel_worker` running across targets, which
        # reads each dependency's kernel once instead of once per target. The
        # last argument is the params file Bazel requires of a worker.
        execution_requirements = PATH_MAPPING | {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )
    return DartModuleInfo(
        modules = depset([out], transitive = [modules.modules], order = "postorder"),
        manifests = depset([manifest], transitive = [modules.manifests], order = "postorder"),
    )

def _add_sdk_args(args, sdk):
    args.add("--runtime", sdk.runtime)
    args.add("--platform", sdk.platform)
    args.add("--target", sdk.target)

def dart_module_aspect(kernel_sdk, extra_dart_defines = Label("//dart:extra_dart_defines"), exec_toolchains = []):
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
        attrs = KERNEL_TOOL_ATTR | {
            "_kernel_sdk": _kernel_sdk_attr(kernel_sdk),
            "_extra_dart_defines": attr.label(default = extra_dart_defines),
            "_module_defines": attr.label(default = Label("//dart/private:module_defines")),
            "_modular_kernel": attr.label(default = Label("//dart:modular_kernel")),
        },
    )

def _kernel_sdk_attr(kernel_sdk):
    # Built for the host the modules compile on: the front end runs there.
    return attr.label(default = kernel_sdk, providers = [DartKernelSdkInfo], cfg = config.exec(PORTABLE))

vm_module_aspect = dart_module_aspect(Label("//dart/private:vm_kernel_sdk"))

_MODULE_DEFINES = str(Label("//dart/private:module_defines"))

def _module_defines_transition_impl(_settings, attr):
    # Checked here, on the executable, rather than only when its first
    # dependency's module is compiled, so the message names the right target.
    for define in attr.defines:
        _check_no_comma(define, "this target's `defines`")
    return {_MODULE_DEFINES: list(attr.defines)}

module_defines_transition = transition(
    implementation = _module_defines_transition_impl,
    inputs = [],
    outputs = [_MODULE_DEFINES],
)

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
      `struct(modules, manifests)` of depsets.
    """
    return _merge_modules([dep[DartModuleInfo] for dep in deps if DartModuleInfo in dep])

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
        defines = [],
        native_assets_yaml = None):
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

    Args:
      ctx: The rule context.
      sdk: The `DartKernelSdkInfo`.
      kernel_tool: The `kernel_tool` executable.
      main: The generated entrypoint File.
      srcs: The executable's own source Files (its entrypoint among them).
      packages: Every `DartPackageInfo` the executable sees, one per name, so
        its files get the language version of the package containing them.
      modules: `struct(modules, manifests)` from `collect_modules`.
      output: The entry `.dill` to write.
      own_package: The `DartPackageInfo` of the package the executable states
        it belongs to, or `None`.
      defines: Environment declarations, `KEY=VALUE`.
      native_assets_yaml: Optional `native_assets.yaml` to embed.

    Returns:
      `struct(modules, manifests, selection)`: every module the executable
      sees, its own included, and the File naming those `main` reaches, to
      link with the entry.
    """
    own = _compile_modules(
        ctx,
        sdk = sdk,
        kernel_tool = kernel_tool,
        name = ctx.label.name + ".own",
        srcs = srcs,
        packages = packages,
        own_package = own_package,
        modules = modules,
        defines = defines,
    )

    package_config = ctx.actions.declare_file(output.basename + ".package_config.json", sibling = output)
    ctx.actions.write(package_config, kernel_package_config(packages))
    selection = ctx.actions.declare_file(output.basename + ".selection.json", sibling = output)

    args = _new_args(ctx)
    args.add("--label", str(ctx.label))
    _add_sdk_args(args, sdk)
    args.add_all([sdk.platform], before_each = "--sdk-root", map_each = _dirname)
    args.add("--package-config", package_config)
    add_kernel_roots(args, "--multi-root", [main])
    _add_deps(args, own.modules)
    args.add_all(sdk.defines + defines, before_each = "--define")
    inputs = [main, package_config, sdk.platform, sdk.frontend_server, sdk.runtime]
    if native_assets_yaml != None:
        args.add("--native-assets", native_assets_yaml)
        inputs.append(native_assets_yaml)
    args.add("--main", main)
    args.add("--output", output)
    args.add("--selection-output", selection)

    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["entry", _snapshot_args(ctx, sdk.frontend_server), args],
        inputs = depset(inputs, transitive = [own.modules, own.manifests, sdk.tool_files]),
        outputs = [output, selection],
        mnemonic = "DartEntryKernel",
        exec_group = PORTABLE,
        progress_message = "Compiling Dart entrypoint %{label}",
        execution_requirements = PATH_MAPPING,
    )
    return struct(modules = own.modules, manifests = own.manifests, selection = selection)

def dart_link_kernel_action(ctx, kernel_tool, entry, linked, output):
    """Links an entry `.dill` and the modules its entrypoint reaches into one program.

    Fails if one library is compiled into two of those modules: the front end
    would silently use one copy, and which one would depend on dependency
    order.

    Args:
      ctx: The rule context.
      kernel_tool: The `kernel_tool` executable.
      entry: The entry `.dill`, from the platform's entrypoint compile.
      linked: `struct(modules, manifests, selection)` from
        `dart_entry_kernel_action`.
      output: The program `.dill` to write.
    """
    args = _new_args(ctx)
    args.add("--label", str(ctx.label))
    args.add("--entry", entry)
    args.add("--selection", linked.selection)
    args.add_all(linked.modules, before_each = "--dep-manifest", map_each = _info_path, expand_directories = False)
    args.add("--output", output)
    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["link", args],
        inputs = depset([entry, linked.selection], transitive = [linked.modules, linked.manifests]),
        outputs = [output],
        mnemonic = "DartLinkKernel",
        exec_group = PORTABLE,
        progress_message = "Linking Dart kernel %{label}",
        execution_requirements = PATH_MAPPING,
    )

def _vm_kernel_sdk_impl(ctx):
    sdk = ctx.toolchains["//dart:toolchain_type"].dart_sdk_info
    root = sdk.dart.dirname.rsplit("/", 1)[0]
    wanted = {
        "runtime": [root + "/bin/dartaotruntime", root + "/bin/dartaotruntime.exe"],
        "kernel_worker": [root + "/bin/snapshots/kernel_worker_aot.dart.snapshot"],
        "frontend_server": [root + "/bin/snapshots/frontend_server_aot.dart.snapshot"],
        "platform": [root + "/lib/_internal/vm_platform_product.dill"],
        "libraries_spec": [root + "/lib/libraries.json"],
    }
    found = {}

    # Once per configuration: a probe for five files in the SDK.
    for f in sdk.tool_files.to_list():
        for key, paths in wanted.items():
            if f.path in paths:
                found[key] = f
    missing = [k for k in wanted if k not in found]
    if missing:
        fail("could not find %s in the Dart %s SDK at %s" % (", ".join(missing), sdk.version, root))
    return [DartKernelSdkInfo(
        target = "vm",
        runtime = found["runtime"],
        kernel_worker = found["kernel_worker"],
        frontend_server = found["frontend_server"],
        platform = found["platform"],
        libraries_spec = found["libraries_spec"],
        libraries_target = "vm",
        # What `dart compile kernel` folds in: a product runtime, no sanitizers.
        defines = ["dart.vm.product=true", "dart.vm.asan=false", "dart.vm.msan=false", "dart.vm.tsan=false"],
        tool_files = sdk.tool_files,
    )]

vm_kernel_sdk = rule(
    implementation = _vm_kernel_sdk_impl,
    toolchains = ["//dart:toolchain_type"],
    doc = "The `DartKernelSdkInfo` for the Dart VM, from the resolved Dart toolchain.",
)
