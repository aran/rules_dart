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
load("//dart/private:common.bzl", "KERNEL_FILESYSTEM_SCHEME", "own_package_record")

_KERNEL_TOOL = Label("//dart/private/tools:kernel_tool")

def kernel_root_path(short_path):
    """A `short_path` as a path under the kernel filesystem roots.

    A file of another repository has a `short_path` of `../<repo>/…` but sits
    at `external/<repo>/…` under the exec root and the output directories.

    Args:
      short_path: A `File.short_path`, or a `lib_root`.

    Returns:
      The root-relative path.
    """
    return "external/" + short_path[3:] if short_path.startswith("../") else short_path

def kernel_roots(files):
    """The kernel filesystem roots `files` are found under, output directories first.

    The exec root, plus the output directory of each generated file; a file's
    root is what is left of its path once its `short_path` is taken off. The
    output directories come first so a generated file wins over a stale copy
    at the same path in the source tree: a sandbox hides the stale one, but a
    persistent worker runs in the exec root, where it is visible.

    Args:
      files: Files a compile reads from source.

    Returns:
      A list of exec-root-relative directories, `.` last.
    """
    roots = {}
    for f in files:
        rel = kernel_root_path(f.short_path)
        if f.path != rel and f.path.endswith("/" + rel):
            roots[f.path[:-len(rel) - 1]] = None
    return list(roots) + ["."]

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

def _info_path(module):
    return module.path + ".json"

def _package_name(pkg):
    return pkg.package_name

def _add_deps(args, modules):
    args.add_all(modules, before_each = "--dep-modules", expand_directories = False)
    args.add_all(modules, before_each = "--dep-manifest", map_each = _info_path, expand_directories = False)

def _new_args(ctx):
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    return args

def _add_layering_args(args, label, deps, indirect_deps):
    """Asks the kernel tool to check that imports name only direct dependencies.

    A package reached only through a dependency's dependency is the
    dependency's business: importing it works only until that dependency
    stops depending on it. So only the packages of `deps` themselves, and the
    target's own, may be imported. A dependency without sources of its own (a
    façade re-exporting its `deps`) stands for everything it reaches, and a
    target's `DartInfo.indirect_deps` (a generator's imports) are accepted by
    the package each of them has in its dependent's `DartInfo.deps`.

    Only for targets of this repository: another repository's dependencies are
    its own (a pub package's are generated from its pubspec), and its
    imports are not this build's to police. A target or build turns the check
    off with the `dart_layering_check` feature (`features =
    ["-dart_layering_check"]`, or `--features=-dart_layering_check`), as
    rules_cc's `layering_check`.

    Args:
      args: The tool's Args.
      label: The target being compiled.
      deps: The targets it depends on directly.
      indirect_deps: Labels from its `DartInfo.indirect_deps`.
    """
    if label.workspace_name:
        return
    args.add("--check-layering")
    facades = []
    for dep in deps:
        if DartInfo not in dep:
            continue
        dep_info = dep[DartInfo]
        if dep_info.package_name:
            args.add("--direct-package", dep_info.package_name)
        if not getattr(dep_info, "srcs", None):
            facades.append(dep_info.transitive_packages)
        for wanted in indirect_deps:
            package = getattr(dep_info, "deps", {}).get(wanted)
            if package:
                args.add("--direct-package", package)
    args.add_all(depset(transitive = facades), before_each = "--direct-package", map_each = _package_name, uniquify = True)

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

# A rule whose `DartInfo` dependencies come from a toolchain rather than an
# attribute (`dart_proto_library`'s protobuf runtime) names the toolchain types
# in a private `label_list` of this name, so the aspect reaches them too.
DART_TOOLCHAIN_TYPES_ATTR = "_dart_toolchain_types"

def _propagated_attrs(ctx):
    # Every attribute but tools: a `DartInfo` dependency can arrive through
    # any of them (`deps`, `dart_deps`, a forwarder's `library`), and which
    # are dependencies is decided by `DartInfo.deps`, not by names.
    return [
        name
        for name in dir(ctx.rule.attr)
        if name != DART_TOOLCHAIN_TYPES_ATTR and not getattr(ctx.rule.attr, name).is_tool
    ]

def _propagated_toolchains(ctx):
    types = getattr(ctx.rule.attr, DART_TOOLCHAIN_TYPES_ATTR, None)
    return list(types.value) if types != None else []

def _reached(ctx):
    """Every target the aspect reached from this one: attributes and toolchains."""
    reached = []
    for name in dir(ctx.rule.attr):
        if name == DART_TOOLCHAIN_TYPES_ATTR:
            continue
        value = getattr(ctx.rule.attr, name)
        if type(value) == "dict":
            value = value.keys()
        elif type(value) != "list":
            value = [value]
        for dep in value:
            if type(dep) == "Target" and DartModuleInfo in dep:
                reached.append(dep)
    for toolchain_type in getattr(ctx.rule.attr, DART_TOOLCHAIN_TYPES_ATTR, []):
        toolchain = ctx.rule.toolchains[toolchain_type.label]
        if toolchain != None and DartModuleInfo in toolchain:
            reached.append(toolchain)
    return reached

def _module_aspect_impl(target, ctx):
    reached = _reached(ctx)

    # Not a library: hand on the libraries it holds (a toolchain's runtime),
    # one hop, for the library that names them in its `DartInfo.deps`.
    if DartInfo not in target:
        return [DartModuleInfo(
            modules = depset(),
            manifests = depset(),
            exported = {dep.label: dep for dep in reached if DartInfo in dep},
        )]
    info = target[DartInfo]

    # A target that passes on a dependency's `DartInfo` (`dart_test_package`
    # handing on `package:test`'s library) passes on its modules too, rather
    # than compiling the same files a second time.
    for dep in reached:
        if DartInfo in dep and dep[DartInfo].srcs == info.srcs and dep[DartInfo].lib_root == info.lib_root:
            return [dep[DartModuleInfo]]

    by_label = {}
    for dep in reached:
        if DartInfo in dep:
            by_label[dep.label] = dep
    for dep in reached:
        for label, exported in getattr(dep[DartModuleInfo], "exported", {}).items():
            by_label.setdefault(label, exported)

    # `getattr`: a provider built before `deps` existed names none; every
    # library reached stands in for it.
    wanted = getattr(info, "deps", None)
    if wanted == None:
        direct = [dep for dep in reached if DartInfo in dep]
    else:
        missing = [label for label in wanted if label not in by_label]
        if missing:
            fail(("%s: depends on %s, but the kernel module aspect cannot reach " +
                  "%s through any attribute. A dependency taken from a toolchain " +
                  "is reached only if the rule lists the toolchain type in `%s`.") %
                 (ctx.label, missing[0], "it" if len(missing) == 1 else "them", DART_TOOLCHAIN_TYPES_ATTR))
        direct = [by_label[label] for label in wanted]
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
        available = info.transitive_packages,
        deps = direct,
        indirect_deps = getattr(info, "indirect_deps", []),
        defines = module_defines(ctx),
    )]

def _merge_modules(infos):
    return struct(
        modules = depset(transitive = [i.modules for i in infos], order = "postorder"),
        manifests = depset(transitive = [i.manifests for i in infos], order = "postorder"),
    )

def _check_no_comma(define, source):
    if "," in define:
        fail(("`%s` (from %s): a Dart define's value cannot contain a comma " +
              "in a test. Its libraries are compiled by `kernel_worker`, which " +
              "splits every `-D` value on commas, so they would see a " +
              "different value than the test does.") % (define, source))

def _compile_modules(ctx, sdk, kernel_tool, name, srcs, packages, own_package, modules, available, deps, indirect_deps, defines):
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
      available: Depset of every `DartPackageInfo` reachable.
      deps: The direct dependency targets, for the layering check.
      indirect_deps: Labels from `DartInfo.indirect_deps`.
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
    if ctx.label.workspace_name:
        # Another repository's dependencies are its own (a pub package's are
        # generated from its pubspec): a file of it importing what none of
        # them provides fails only an importer that reaches it.
        args.add("--tolerate-policy")
    args.add_all(kernel_roots(srcs), before_each = "--multi-root")
    args.add_all(srcs, before_each = "--src", expand_directories = False)
    _add_deps(args, modules.modules)
    args.add_all(available, before_each = "--available-package", map_each = _package_name, uniquify = True)
    if "dart_layering_check" not in ctx.disabled_features:
        _add_layering_args(args, ctx.label, deps, indirect_deps)
    args.add_all(sdk.defines + defines, before_each = "--define")
    args.add("--output-dir", out.path)
    args.add("--manifest-output", manifest)

    ctx.actions.run(
        executable = kernel_tool,
        arguments = ["module", "--snapshot", sdk.kernel_worker.path, args],
        inputs = depset(
            srcs + [package_config, sdk.libraries_spec, sdk.platform, sdk.kernel_worker, sdk.runtime],
            transitive = [modules.modules, modules.manifests, sdk.tool_files],
        ),
        # The SDK's compiler is a tool, so that a different one (a new SDK, a
        # different snapshot) is a different worker, not the old one reused.
        tools = [sdk.kernel_worker, sdk.runtime],
        outputs = [out, manifest],
        mnemonic = "DartModule",
        progress_message = "Compiling Dart modules %{label}",
        # `kernel_tool` keeps one `kernel_worker` running across targets, which
        # reads each dependency's kernel once instead of once per target. The
        # last argument is the params file Bazel requires of a worker.
        execution_requirements = {
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

def dart_module_aspect(kernel_sdk, extra_dart_defines = Label("//dart:extra_dart_defines")):
    """Makes the aspect that compiles every `DartInfo` target to a kernel module.

    Call it at the top level of a `.bzl` file and assign the result, once per
    platform; rules_dart's own is `vm_module_aspect`. Attach it to an
    executable's `deps` (`attr.label_list(aspects = [...])`), compile the
    entrypoint against `DartModuleInfo.modules`, and link with
    `dart_link_kernel_action`.

    Args:
      kernel_sdk: Label of a target providing `DartKernelSdkInfo`.
      extra_dart_defines: The command-line defines flag the executables read,
        so a dependency's module folds the same declarations as the
        entrypoint compiled against it.

    Returns:
      The aspect.
    """
    return aspect(
        implementation = _module_aspect_impl,
        attr_aspects = _propagated_attrs,
        toolchains_aspects = _propagated_toolchains,
        attrs = {
            "_kernel_sdk": attr.label(default = kernel_sdk, providers = [DartKernelSdkInfo]),
            "_kernel_tool": attr.label(default = _KERNEL_TOOL, executable = True, cfg = "exec"),
            "_extra_dart_defines": attr.label(default = extra_dart_defines),
            "_module_defines": attr.label(default = Label("//dart/private:module_defines")),
        },
    )

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
# through the module aspect and the defines transition, and the tools.
KERNEL_TOOL_ATTR = {
    "_kernel_tool": attr.label(default = _KERNEL_TOOL, executable = True, cfg = "exec"),
}

MODULE_EXECUTABLE_ATTRS = KERNEL_TOOL_ATTR | {
    "_kernel_sdk": attr.label(default = Label("//dart/private:vm_kernel_sdk"), providers = [DartKernelSdkInfo]),
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
        deps,
        output,
        own_package = None,
        defines = [],
        native_assets_yaml = None):
    """Compiles an executable against the modules its entrypoint reaches.

    The executable's own files (`srcs`) are compiled into modules like any
    library's, checked the same way and keeping their line numbers. `main` — a
    generated entrypoint such as a test bootstrap — is compiled on its own by
    `frontend_server`, because that is what records the program's `main` and
    `kernel_worker` never does; `frontend_server` drops the source positions
    of whatever it compiles against modules, which costs only `main`'s own
    frames. `main` is generated, so its imports are not checked against
    `deps`. Only the modules `main` reaches are compiled against and, by
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
      deps: The executable's direct dependencies, whose packages alone its
        own files may import.
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
        available = depset(packages),
        deps = deps,
        indirect_deps = [],
        defines = defines,
    )

    package_config = ctx.actions.declare_file(output.basename + ".package_config.json", sibling = output)
    ctx.actions.write(package_config, kernel_package_config(packages))
    selection = ctx.actions.declare_file(output.basename + ".selection.json", sibling = output)

    args = _new_args(ctx)
    args.add("--label", str(ctx.label))
    _add_sdk_args(args, sdk)
    args.add("--sdk-root", sdk.sdk_root)
    args.add("--package-config", package_config)
    args.add_all(kernel_roots([main]), before_each = "--multi-root")
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
        arguments = ["entry", "--snapshot", sdk.frontend_server.path, args],
        inputs = depset(inputs, transitive = [own.modules, own.manifests, sdk.tool_files]),
        outputs = [output, selection],
        mnemonic = "DartEntryKernel",
        progress_message = "Compiling Dart entrypoint %{label}",
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
        progress_message = "Linking Dart kernel %{label}",
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
        sdk_root = found["platform"].dirname,
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
