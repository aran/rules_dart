"""Modular kernel compilation for `dart_library` and `dart_test`.

Whole-program compilation puts every package in an executable's closure into that
executable's own kernel. With 30 tests, `package:test` is compiled 30 times, and a
one-line edit in a leaf library recompiles every test that reaches it.

Modular compilation splits the work along `dart_library` boundaries. Each library
compiles its own sources into a module: a `.kmod` directory of one kernel per
component of its sources (with embedded source text stripped), a `.koutline`
directory of deterministic outline kernels for downstream `--input-summary`
compiles, and an index that lists them. Any class that can be used as a mixin
(`mixin`, `mixin class`, and every class in a library whose language version is
below 3.0) keeps its member bodies and field initializers in `.koutline`. Both
binary strippers check the 32-bit kernel format version in the header (accepting
version 138, Dart 3.13.x) and log a diagnostic to `stderr` while falling back to
the unstripped `.dill` bytes on any other version. An executable compiles only
its entry module, and links the `.kmod` kernels it reaches through the indexes,
in dependency order, which the VM runs as one program. A kernel nothing reaches
is never linked.

A module's package config names every package by a multi-root URI,
`org-dartlang-bazel:///<path>`. The compiler resolves that against the source tree
and the output tree alike, so a package split between the two (a `dart_codegen`
part) is read where it lies and never copied.

A module compiles the sources its library declares that can compile for the VM.
`kernel_module` decides which those are from the import graph, before it compiles:
a source that imports a `dart:` library the VM lacks, or a file that is excluded,
is excluded, and so is every source that imports one. The excluded sources are
listed in the module's `.vm_excluded.txt` sidecar, which the modules above it read.
An executable whose entry module reaches an excluded file compiles that file from
source, so it fails exactly as a whole-program compile would when the VM cannot run
it.

Every decision that can send an executable back to whole-program compilation is a
pure function here, so each can be unit tested. The actions are built only when a
consumer needs them, so a library used only by AOT binaries never compiles its
module.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartInfo", _DartKernelInfo = "DartKernelInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR")
load(
    "//dart/private:common.bzl",
    "STABLE_SCHEME",
    "collect_transitive_srcs",
    "generate_stable_package_config",
    "own_package_record",
    "sdk_path_from_dart",
    "stable_path",
)
load("//dart/private:dart_info.bzl", "package_lib_prefix")

# The `org-dartlang-bazel` scheme `--multi-root` maps onto the exec root (`.`) and
# the output directory (`ctx.bin_dir`). Its URIs are the exec-root-relative paths
# a `File.short_path` already gives, so no path is copied or rewritten to make a
# generated file reachable.

_TOOLCHAIN_TYPE = Label("//dart:toolchain_type")
EXEC_TOOLS_TOOLCHAIN = Label("//dart:exec_tools_toolchain_type")

DartKernelInfo = _DartKernelInfo

def _kernel_module_for_mode(compile_mode, modular_kernel):
    if compile_mode == "kernel" and modular_kernel:
        return Label("//dart/private/tools:kernel_module")
    return None

def _kernel_link_for_mode(compile_mode, modular_kernel):
    if compile_mode == "kernel" and modular_kernel:
        return Label("//dart/private/tools:kernel_link")
    return None

# The build setting and the module compiler. `dart_library` takes these (its
# module), `dart_test` takes `MODULAR_KERNEL_ATTRS`, and `dart_binary` takes
# `BINARY_MODULAR_KERNEL_ATTRS` (which resolves the tools only for `kernel` mode,
# so an `exe` tool like `kernel_module` or `kernel_link` never depends on itself).
#
# `kernel_module` is a `dart_binary` with no pub dependencies, so it reaches no
# `dart_library` and no cycle is possible.
KERNEL_MODULE_ATTRS = {
    "_modular_kernel": attr.label(
        doc = "The `//dart:modular_kernel` build setting. When off, executables compile whole-program as before.",
        default = Label("//dart:modular_kernel"),
        providers = [BuildSettingInfo],
    ),
    "_kernel_module": attr.label(
        doc = "The tool that compiles one module with `kernel_worker`, excluding the sources that cannot compile for the VM. See `kernel_module.dart`.",
        default = Label("//dart/private/tools:kernel_module"),
        executable = True,
        cfg = "exec",
    ),
    "_kernel_link": attr.label(
        doc = "The tool that links an executable's kernel from the kernels its entry reaches. See `kernel_link.dart`.",
        default = Label("//dart/private/tools:kernel_link"),
        executable = True,
        cfg = "exec",
    ),
}

MODULAR_KERNEL_ATTRS = dict(KERNEL_MODULE_ATTRS)

BINARY_MODULAR_KERNEL_ATTRS = {
    "modular_kernel": attr.bool(
        default = True,
        doc = "Whether `compile_mode = \"kernel\"` compiles modularly against dependency `.kmod` outputs when eligible.",
    ),
    "_modular_kernel": KERNEL_MODULE_ATTRS["_modular_kernel"],
    "_kernel_module": attr.label(
        doc = "The tool that compiles one module with `kernel_worker`, when `compile_mode` is `kernel`.",
        default = _kernel_module_for_mode,
        executable = True,
        cfg = "exec",
    ),
    "_kernel_link": attr.label(
        doc = "The tool that links an executable's kernel from the kernels its entry reaches, when `compile_mode` is `kernel`.",
        default = _kernel_link_for_mode,
        executable = True,
        cfg = "exec",
    ),
}

# Optional, so a build that registers no exec tools toolchain keeps compiling
# whole-program rather than failing. See `kernel_tools_for`.
MODULAR_KERNEL_TOOLCHAINS = [
    config_common.toolchain_type(EXEC_TOOLS_TOOLCHAIN, mandatory = False),
]

def multi_root_uri(short_path, scheme = STABLE_SCHEME):
    """The multi-root URI for a path, or for a package root.

    The URI is the shared stable URI of `common.bzl`, so the module compile and the
    whole-program compile name a file the same way. The root package's empty
    `lib_root` maps to the bare scheme root, which the scheme's roots resolve to the
    exec root and the output directory.

    Args:
        short_path: A `File.short_path`, or a `DartPackageInfo.lib_root`.
        scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
        The URI string, e.g. `org-dartlang-bazel:///pkg/a`.
    """
    return scheme + ":///" + stable_path(short_path)

def entry_source_uri(short_path, scheme = STABLE_SCHEME):
    """The URI an entry module's source is compiled under.

    Entry sources are addressed by where they sit, not by `package:` name, because
    a test reaches its own files by relative path and that path has to resolve the
    way it does in the monolithic compile.

    Args:
      short_path: The source's `File.short_path`.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
      The URI string.
    """
    return multi_root_uri(short_path, scheme = scheme)

def library_source_uri(package_name, lib_root, short_path):
    """The `package:` URI of a library's own source.

    The file's `short_path` lies under `<lib_root>/lib/`, which `dart_library`
    enforces. The URI is that path relative to `lib/`, so the package config's
    root for the package turns it back into the same file.

    Args:
      package_name: The package the library declares.
      lib_root: The package's `lib_root`; empty for the root package.
      short_path: The source's `File.short_path`.

    Returns:
      The URI string, e.g. `package:a/src/x.dart`.
    """
    prefix = package_lib_prefix(lib_root)
    return "package:%s/%s" % (package_name, short_path[len(prefix):])

def kernel_package_config(packages, scheme = STABLE_SCHEME):
    """The package config a module or an entry compiles against.

    `generate_stable_package_config` with every package kept. Its filter drops a
    package no file of `all_srcs` lives in, and a module must keep every package its
    own sources may import, whichever files they are, so every name is given as a
    root.

    Args:
        packages: `DartPackageInfo` records, one per package name.
        scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
        The `package_config.json` content.
    """
    return generate_stable_package_config(
        packages,
        [],
        roots = {pkg.package_name: True for pkg in packages},
        scheme = scheme,
    )

def kernel_packages_consistent(records):
    """Whether a closure's package records fit one multi-root URI per name.

    A package config holds one `rootUri` per name. Two `lib_root`s under one name
    (a package split across targets that sit in different directories, or two pub
    hubs) cannot both be named, so the closure must compile whole-program. Two
    root packages cannot share the bare scheme root either.

    Args:
      records: `DartPackageInfo` records, duplicates kept.

    Returns:
      True when every name has one `lib_root` and at most one package is the root.
    """
    root_of = {}
    root_names = {}
    for pkg in records:
        seen = root_of.get(pkg.package_name)
        if seen == None:
            root_of[pkg.package_name] = pkg.lib_root
        elif seen != pkg.lib_root:
            return False
        if not pkg.lib_root:
            root_names[pkg.package_name] = True
    return len(root_names) <= 1

def first_per_package(records):
    """Keeps the first record for each package name, in order.

    Used for a module's package config, after `kernel_packages_consistent` has
    confirmed that a name never appears with two roots. Unlike
    `merge_package_records` this does not compare versions: a library analysed
    alone should not fail on a disagreement that only an executable reaching both
    could see, and that executable's own `merge_package_records` still reports it.

    Args:
      records: `DartPackageInfo` records, duplicates kept.

    Returns:
      One record per package name.
    """
    seen = {}
    out = []
    for pkg in records:
        if pkg.package_name in seen:
            continue
        seen[pkg.package_name] = True
        out.append(pkg)
    return out

def duplicated_source(own_paths, owned, edges):
    """The source a modular executable cannot compile, or None.

    Each `dart_library` compiles the sources it lists into its module, and the
    executable links the modules it reaches. Within one dependency chain the planner
    in `kernel_module.dart` keeps one definition of a source: a library whose
    dependency module already defines the source does not compile it again. Two
    libraries that do not depend on each other each compile their own copy, and the
    executable would link two kernels that define one library. The frontend refuses
    that, and a whole-program compile merges the copies by file, so it never saw the
    problem. Such an executable falls back to whole-program compilation.

    The executable's own sources are compiled by its entry module, which does not
    dedupe against the libraries, so a source it shares with a library falls back too.

    Args:
      own_paths: The `short_path` of each of the executable's own sources.
      owned: The `(label, short_path)` of each source of each library in its closure.
      edges: The `(label, dep_label)` of each `dart_library` dependency in its closure.

    Returns:
      The `short_path` of the first source that cannot compile modularly, or None.
    """
    own = {}
    for path in own_paths:
        own[path] = True
    owners = {}
    for label, path in owned:
        if path in own:
            return path
        owners.setdefault(path, {})[label] = True
    reaches = {}
    for label, dep in edges:
        reaches.setdefault(label, {})[dep] = True
    for path in sorted(owners.keys()):
        labels = sorted(owners[path].keys())
        for i in range(len(labels)):
            for j in range(i + 1, len(labels)):
                first = labels[i]
                second = labels[j]
                if not _depends_on(reaches, first, second) and not _depends_on(reaches, second, first):
                    return path
    return None

def _depends_on(reaches, label, target):
    """Whether `label` depends on `target`, directly or through other libraries.

    Args:
      reaches: The `label` -> {dep_label: True} edges of the closure.
      label: The depending label.
      target: The label it may depend on.

    Returns:
      True when `target` is reached from `label` by at least one edge.
    """
    visited = {label: True}
    frontier = [label]
    for _ in range(len(reaches) + 1):
        if not frontier:
            break
        following = []
        for current in frontier:
            for dep in reaches.get(current, {}):
                if dep == target:
                    return True
                if dep not in visited:
                    visited[dep] = True
                    following.append(dep)
        frontier = following
    return False

def modular_kernel_eligible(
        enabled,
        kernel_mode,
        dep_modular,
        packages_consistent,
        has_code_assets,
        has_own_defines,
        has_compile_flags,
        has_duplicate_source,
        same_sdk,
        has_comma_defines = False):
    """Whether one executable compiles modularly, given every fact that decides it.

    Each `False` is a reason the executable falls back to whole-program compilation,
    which is always correct, only slower.

    Args:
      enabled: The `//dart:modular_kernel` flag.
      kernel_mode: Whether the executable is a kernel (`dart_test` always is).
      dep_modular: Whether every dependency's closure is modular.
      packages_consistent: `kernel_packages_consistent` over the executable's closure.
      has_code_assets: Whether native code assets are embedded in the kernel. The
        embedding runs the front end over the whole program at once.
      has_own_defines: Whether the executable's own `defines` attribute is set.
        Modules compile with the `//dart:extra_dart_defines` flag, which is the same
        for the whole build, so the flag's `-D`s are shared by every module. Only a
        target's own `defines` cannot be shared, so only they fall back.
      has_compile_flags: Whether `dart_compile_flags` are set. They reach
        `dart compile`, which the modular path does not run.
      has_duplicate_source: Whether `duplicated_source` found a repeat.
      same_sdk: Whether the exec and target SDKs report the same version. A kernel
        compiled by one is loaded by the other, and the VM accepts only its own
        kernel format.

    Returns:
      True when the executable compiles modularly.
    """
    return (
        enabled and
        kernel_mode and
        dep_modular and
        packages_consistent and
        not has_code_assets and
        not has_own_defines and
        not has_comma_defines and
        not has_compile_flags and
        not has_duplicate_source and
        same_sdk
    )

def find_kernel_module_tools(dart_sdk_info):
    """Locates the files a module compile and a link run from, in an SDK.

    The worker snapshot `kernel_worker_aot.dart.snapshot` is absent from older SDKs.
    Its absence is not an error: the library compiles no module and every consumer
    compiles whole-program, exactly as it did before modular compilation existed.

    Args:
      dart_sdk_info: The `DartSdkInfo` of the exec tools toolchain.

    Returns:
      `struct(dartaotruntime, kernel_worker, platform_dill, libraries_json,
      version)`, or None
      when the SDK lacks the worker snapshot.
    """
    sdk_root = sdk_path_from_dart(dart_sdk_info.dart)
    dartvm_paths = [
        sdk_root + "/bin/dartvm",
        sdk_root + "/bin/dartvm.exe",
    ]
    wanted = {
        "dartaotruntime": [
            sdk_root + "/bin/dartaotruntime",
            sdk_root + "/bin/dartaotruntime.exe",
        ],
        "kernel_worker": [sdk_root + "/bin/snapshots/kernel_worker_aot.dart.snapshot"],
        "platform_dill": [sdk_root + "/lib/_internal/vm_platform_strong.dill"],
        "libraries_json": [sdk_root + "/lib/libraries.json"],
    }
    dartvm = None
    found = {}
    for f in dart_sdk_info.compile_files.to_list():
        if f.path in dartvm_paths:
            dartvm = f
        for key, paths in wanted.items():
            if f.path in paths:
                found[key] = f
    if len(found) != len(wanted):
        return None
    return struct(
        dart = dart_sdk_info.dart,
        dartvm = dartvm,
        runtime_files = dart_sdk_info.runtime_files,
        dartaotruntime = found["dartaotruntime"],
        kernel_worker = found["kernel_worker"],
        platform_dill = found["platform_dill"],
        libraries_json = found["libraries_json"],
        version = dart_sdk_info.version,
    )

def kernel_tools_for(ctx):
    """The exec SDK's kernel tools for a rule, or None when modular compile cannot run.

    Modules are built on the exec platform. A kernel is platform-independent, and
    the exec SDK is the one that runs on the machine doing the build.

    Args:
      ctx: A rule context that declares `EXEC_TOOLS_TOOLCHAIN`, optionally.

    Returns:
      The struct from `find_kernel_module_tools`, or None.
    """
    toolchain = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN]
    if toolchain == None:
        return None
    return find_kernel_module_tools(toolchain.dart_sdk_info)

def dep_kernels_or_none(deps):
    """The `DartKernelInfo` of each dependency, or None if any lacks one.

    Args:
      deps: The `deps` attribute's targets.

    Returns:
      A list of `DartKernelInfo`, or None.
    """
    out = []
    for dep in deps:
        if DartKernelInfo not in dep:
            return None
        out.append(dep[DartKernelInfo])
    return out

def no_kernel_module():
    """The `DartKernelInfo` of a library that compiles no module and is not modular.

    Returns:
      A `DartKernelInfo` whose `modular` is False.
    """
    return DartKernelInfo(
        kmod = None,
        koutline = None,
        transitive_kmods = depset(order = "postorder"),
        transitive_koutlines = depset(order = "postorder"),
        modular = False,
        closure_excluded = depset(),
        cross_pkg_srcs = depset(),
        owned = depset(),
        edges = depset(),
        base_dill = None,
        base_keys = None,
        base_kmods = depset(),
        unseeded_base_kmods = depset(),
    )

def kernel_module_action(
        ctx,
        tools,
        sources,
        packages,
        dep_kmods,
        output,
        defines,
        exclude_non_sources,
        droppable,
        koutline = None,
        extra_inputs = None,
        closure_excluded = None,
        target = "vm",
        platform_dill = None,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = [],
        scheme = STABLE_SCHEME,
        extra_frontend_flags = []):
    """Compiles one module with `kernel_module`, which drives the persistent `kernel_worker`.

    `kernel_module` is a Bazel persistent worker: it keeps one `kernel_worker` child
    running, so each module compile reuses the loaded SDK, and a retry reuses the
    same child. Everything except the wrapper's startup flags goes in a params file,
    which keeps long dependency lists off the command line.

    Args:
      ctx: The rule context, carrying the `_kernel_module` executable.
      tools: The struct from `find_kernel_module_tools`.
      sources: `struct(uri, file)` for each source the module compiles. The URI is
        the one the source is compiled under.
      packages: The `DartPackageInfo` records the module's package config names.
      dep_kmods: Postorder depset of the module directories it links against.
      output: The module's directory File to produce. It holds one kernel per
        component of the module's sources, and an `index.json` that lists them.
      defines: The `-D` declarations every compile of this module takes. The
        `//dart:extra_dart_defines` flag, the same for the whole build.
      exclude_non_sources: Whether to emit only the listed sources, and not the
        libraries reached through them. Both kinds pass True, so a module holds its
        own libraries and an entry holds its own sources, and neither embeds the SDK
        platform or a dependency library.
      droppable: Whether `kernel_module` may retry once without the own sources
        that fail for the VM. A library's module may, and one that still fails fails
        the action. An entry module may not: dropping one of the test's own files
        would silently run a test without it.
      koutline: Optional directory File to receive stripped `.dill` outlines and
        `index.json` for downstream `--input-kmod` compilation.
      extra_inputs: A depset of files the compile may read beyond `sources`, such as
        the closure's sources, which an entry module compiles from when it reaches
        an excluded file. None for a library.
      closure_excluded: A depset of the `.vm_excluded.txt` sidecars of the
        module's upstream modules. None when there are none.
      target: The `kernel_worker --target` name (`"vm"` by default; `"flutter"`
        for Flutter modules).
      platform_dill: The platform `.dill` File to compile against; defaults to
        `tools.platform_dill`.
      libraries_json: The `libraries.json` File the planner reads available `dart:`
        libraries from; defaults to `tools.libraries_json`.
      libraries_platform: Optional platform key in `libraries.json` (in addition to
        `"vm"`) whose libraries are available on the target.
      extra_libraries: Extra bare `dart:` library names (e.g. `["ui", "nativewrappers"]`)
        available in `platform_dill` even when absent from `libraries.json`.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
      extra_frontend_flags: Extra flags forwarded to `kernel_worker`.

    Returns:
      The `.vm_excluded.txt` sidecar File, which lists each source that the module
      excludes for the target, and why.
    """
    platform = platform_dill if platform_dill != None else tools.platform_dill
    libraries = libraries_json if libraries_json != None else tools.libraries_json
    package_config = ctx.actions.declare_file(output.basename + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = kernel_package_config(packages, scheme = scheme),
    )
    excluded = ctx.actions.declare_file(output.basename + ".vm_excluded.txt")

    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")

    args.add("--target", target)
    args.add("--dart-sdk-summary", platform)
    args.add("--packages-file", package_config)
    args.add("--libraries-json", libraries)
    if libraries_platform:
        args.add("--libraries-platform", libraries_platform)
    args.add_all(extra_libraries, before_each = "--extra-library")
    args.add("--multi-root", ctx.bin_dir.path)
    args.add("--multi-root", ".")
    args.add("--multi-root-scheme", scheme)
    args.add_all([d for d in defines if "," not in d], format_each = "-D%s")
    args.add_all(extra_frontend_flags)

    # The VM target does not support `--summary-only`: it prints an error and
    # embeds the whole platform. Its absence keeps each kernel to its own libraries.
    args.add("--no-summary-only")

    # The worker keeps the platform and the dependency kernels loaded between
    # requests, and reuses a result when a request repeats. It reads a file only
    # through an input Bazel declared, and every request sends those inputs with
    # their digests, so it never reads a file it was not given.
    args.add("--reuse-compiler-result")
    args.add("--use-incremental-compiler")
    if exclude_non_sources:
        args.add("--exclude-non-sources")

    # A module directory is one argument, not its files: `expand_directories` is off.
    args.add_all(dep_kmods, before_each = "--input-kmod", expand_directories = False)
    for s in sources:
        args.add("--source", s.uri)
    args.add("--output", output.path)
    if koutline != None:
        args.add("--output-outline", koutline.path)

    # Read by `kernel_module` and not passed to `kernel_worker`.
    args.add("--excluded-output", excluded)
    if not droppable:
        args.add("--no-drop")
    if closure_excluded:
        args.add_all(closure_excluded, before_each = "--closure-excluded")

    dart_exe = getattr(tools, "dart", None)
    dartvm = getattr(tools, "dartvm", None)
    runtime_files = getattr(tools, "runtime_files", None)
    direct_inputs = [
        package_config,
        tools.dartaotruntime,
        tools.kernel_worker,
        libraries,
        platform,
    ] + [s.file for s in sources]
    action_tools = [
        tools.dartaotruntime,
        tools.kernel_worker,
        platform,
        ctx.executable._kernel_module,
    ]
    if dart_exe != None:
        direct_inputs.extend([ctx.executable._kernel_module, dart_exe])
        action_tools.append(dart_exe)
        if dartvm != None:
            direct_inputs.append(dartvm)
            action_tools.append(dartvm)
        executable = dart_exe
        arguments = [
            ctx.executable._kernel_module.path,
            "--kernel-worker",
            tools.kernel_worker.path,
            "--dartaotruntime",
            tools.dartaotruntime.path,
            args,
        ]
    else:
        executable = ctx.executable._kernel_module
        arguments = [
            "--kernel-worker",
            tools.kernel_worker.path,
            "--dartaotruntime",
            tools.dartaotruntime.path,
            args,
        ]

    ctx.actions.run(
        executable = executable,
        # The startup arguments name the SDK's compiler, so every module of one SDK
        # shares one worker. Bazel keeps the process running as a worker, and sends
        # each request's arguments through the params file.
        arguments = arguments,
        inputs = depset(
            direct = direct_inputs,
            transitive = [dep_kmods] + [
                d
                for d in [extra_inputs, closure_excluded]
                if d
            ],
        ),
        tools = depset(
            direct = action_tools,
            transitive = [runtime_files] if runtime_files != None else [],
        ),
        outputs = [output, excluded] + ([koutline] if koutline != None else []),
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel module %s" % output.short_path,
        execution_requirements = {} if _is_manual(ctx) else {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )
    return excluded

def _is_manual(ctx):
    if ctx.label.package.startswith("flutter/tests"):
        return True
    tags = getattr(ctx.attr, "tags", None)
    if tags == None and hasattr(ctx, "rule"):
        tags = getattr(ctx.rule.attr, "tags", None)
    return tags != None and "manual" in tags

def kernel_link_action(
        ctx,
        dep_kmods,
        entry = None,
        output = None,
        seed_modules = [],
        base_keys = None,
        write_keys = None,
        platform_dill = None):
    """Links an executable's or base module's kernel from reachable module kernels.

    `kernel_link` reads each module's `index.json`, and writes the kernels reachable
    from the entry's imports (or `seed_modules`), each after the kernels it imports,
    then the entry's own. The link tool reads only these directories, so it needs no
    SDK as an input unless `platform_dill` is provided.

    Args:
      ctx: The rule context, carrying the `_kernel_link` executable.
      dep_kmods: Postorder depset of the dependency module directories.
      entry: The entry module's directory, which holds its kernel and index, or
        None when linking a shared base `.dill` from `seed_modules`.
      output: The linked kernel File to produce.
      seed_modules: List of module directories to seed reachability from when
        linking a shared base `.dill`.
      base_keys: Optional `.keys` File listing `<kmod>:<dill>` SCCs already present
        in a shared base `.dill` (to skip emitting into `output`).
      write_keys: Optional `.keys` File to write the emitted `<kmod>:<dill>` keys to.
      platform_dill: Optional platform `.dill` File to prepend as the first
        sub-component in `output`.
    """

    # The module list can run long, and a Windows command line has a length limit,
    # so the arguments go in a params file. The tool expands it.
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    if write_keys != None:
        args.add("--write-keys", write_keys)
    if base_keys != None:
        args.add("--base-keys", base_keys)
    for seed in seed_modules:
        args.add("--seed-module", seed.path)
    if platform_dill != None:
        args.add("--platform", platform_dill)
    args.add(output)
    if entry != None:
        args.add(entry.path)
    args.add_all(dep_kmods, expand_directories = False)

    direct_inputs = []
    if entry != None:
        direct_inputs.append(entry)
    direct_inputs.extend(seed_modules)
    if base_keys != None:
        direct_inputs.append(base_keys)
    if platform_dill != None:
        direct_inputs.append(platform_dill)

    outputs = [output]
    if write_keys != None:
        outputs.append(write_keys)

    exec_tc = ctx.toolchains[EXEC_TOOLS_TOOLCHAIN] if EXEC_TOOLS_TOOLCHAIN in ctx.toolchains else None
    exec_sdk = exec_tc.dart_sdk_info if exec_tc != None else None
    link_tools = [ctx.executable._kernel_link] + ([platform_dill] if platform_dill != None else [])
    if exec_sdk != None:
        direct_inputs.append(ctx.executable._kernel_link)
        link_tools.append(exec_sdk.dart)
        executable = exec_sdk.dart
        arguments = [ctx.executable._kernel_link.path, args]
        transitive_inputs = [dep_kmods, exec_sdk.runtime_files]
        link_tool_depsets = [exec_sdk.runtime_files]
    else:
        executable = ctx.executable._kernel_link
        arguments = [args]
        transitive_inputs = [dep_kmods]
        link_tool_depsets = []

    ctx.actions.run(
        executable = executable,
        arguments = arguments,
        inputs = depset(direct = direct_inputs, transitive = transitive_inputs),
        tools = depset(direct = link_tools, transitive = link_tool_depsets),
        outputs = outputs,
        mnemonic = "DartKernelLink",
        progress_message = "Linking Dart kernel %s" % ctx.label,
        execution_requirements = {} if _is_manual(ctx) else {
            "supports-workers": "1",
            "requires-worker-protocol": "proto",
        },
    )

def entry_sources(files, scheme = STABLE_SCHEME):
    """Pairs each entry file with the URI it is compiled under.

    Args:
      files: The entry module's files, its entry point first.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).

    Returns:
      A list of `struct(uri, file)`.
    """
    return [struct(uri = entry_source_uri(f.short_path, scheme = scheme), file = f) for f in files]

def global_dart_defines(ctx):
    """The `//dart:extra_dart_defines` flag's values, shared by every module of a build.

    Args:
      ctx: A rule context carrying `_extra_dart_defines` (`EXTRA_DART_DEFINES_ATTR`).

    Returns:
      The list of `KEY` or `KEY=VALUE` strings.
    """
    if not hasattr(ctx.attr, "_extra_dart_defines"):
        return []
    return ctx.attr._extra_dart_defines[BuildSettingInfo].value

def modular_executable_tools(
        ctx,
        own_files,
        own_record,
        kernel_mode,
        resolved_assets,
        own_defines,
        compile_flags):
    """Decides whether an executable compiles modularly, and with which tools.

    Reads the flag and gathers each fact `modular_kernel_eligible` takes. The
    caller then compiles modularly only when this returns tools.

    Args:
      ctx: The executable's rule context, carrying `MODULAR_KERNEL_ATTRS` and
        `deps`.
      own_files: The executable's own `.dart` files, its entry point first.
      own_record: The executable's own `DartPackageInfo`, or None.
      kernel_mode: Whether the executable is compiled as a kernel.
      resolved_assets: The code assets resolved for the executable.
      own_defines: The executable's own `defines` attribute. The
        `//dart:extra_dart_defines` flag is not among them: every module takes it.
      compile_flags: The executable's `dart_compile_flags`.

    Returns:
      The struct from `find_kernel_module_tools`, or None.
    """
    enabled = ctx.attr._modular_kernel[BuildSettingInfo].value if hasattr(ctx.attr, "_modular_kernel") else True
    if not enabled or not kernel_mode:
        return None
    tools = kernel_tools_for(ctx)
    if tools == None:
        return None
    target_sdk = ctx.toolchains[_TOOLCHAIN_TYPE].dart_sdk_info

    kernels = dep_kernels_or_none(ctx.attr.deps)
    dep_modular = kernels != None and all([k.modular for k in kernels])

    records = depset(transitive = [dep[DartInfo].transitive_packages for dep in ctx.attr.deps]).to_list()
    if own_record != None:
        records = [own_record] + records

    owned = depset(transitive = [k.owned for k in kernels or []]).to_list()
    edges = depset(transitive = [k.edges for k in kernels or []]).to_list()
    duplicate = duplicated_source([f.short_path for f in own_files], owned, edges)

    has_comma_defines = any(["," in d for d in global_dart_defines(ctx)])
    eligible = modular_kernel_eligible(
        enabled = enabled,
        kernel_mode = kernel_mode,
        dep_modular = dep_modular,
        packages_consistent = kernel_packages_consistent(records),
        has_code_assets = len(resolved_assets) > 0,
        has_own_defines = len(own_defines) > 0,
        has_compile_flags = len(compile_flags) > 0,
        has_duplicate_source = duplicate != None,
        same_sdk = tools.version == target_sdk.version,
        has_comma_defines = has_comma_defines,
    )
    return tools if eligible else None

def modular_executable_kernel(
        ctx,
        tools,
        sources,
        packages,
        dep_kernels,
        output,
        target = "vm",
        platform_dill = None,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = [],
        scheme = STABLE_SCHEME,
        extra_frontend_flags = [],
        use_base_dill = False):
    """Compiles an executable's entry module, then links it to `output`.

    The entry compiles from source whatever it reaches that no dependency module
    holds, so it takes the closure's sources as inputs: an excluded file is among
    them, and the entry compiles it from source.

    Args:
      ctx: The rule context.
      tools: The struct from `find_kernel_module_tools`.
      sources: The entry module's `struct(uri, file)` list, its entry point first.
      packages: The executable's `DartPackageInfo` records, its own first.
      dep_kernels: The `DartKernelInfo` of each direct dependency.
      output: The linked kernel File the executable runs.
      target: The `kernel_worker --target` name (`"vm"` by default).
      platform_dill: Optional platform `.dill` File override.
      libraries_json: Optional `libraries.json` File override.
      libraries_platform: Optional platform key in `libraries.json`.
      extra_libraries: Extra bare `dart:` library names available on the target.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
      extra_frontend_flags: Extra flags forwarded to `kernel_worker`.
      use_base_dill: When True, links `output` as a delta against any shared
        `base_dill`/`base_keys` provided in `dep_kernels` and returns `base_dill`.

    Returns:
      The shared `base_dill` File if `use_base_dill` is True and a dependency
      provides one, or None.
    """
    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    cross_pkg_srcs = depset(
        transitive = [k.cross_pkg_srcs for k in dep_kernels],
    )
    entry = ctx.actions.declare_directory(ctx.label.name + ".entry.kmod")
    kernel_module_action(
        ctx,
        tools,
        sources,
        packages,
        dep_outline_closure,
        entry,
        defines = global_dart_defines(ctx),
        exclude_non_sources = True,
        droppable = False,
        extra_inputs = cross_pkg_srcs,
        closure_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels]),
        target = target,
        platform_dill = platform_dill,
        libraries_json = libraries_json,
        libraries_platform = libraries_platform,
        extra_libraries = extra_libraries,
        scheme = scheme,
        extra_frontend_flags = extra_frontend_flags,
    )
    base_dill = None
    base_keys = None
    base_kmods = depset()
    unseeded_candidates = None
    if use_base_dill:
        for k in dep_kernels:
            kd = getattr(k, "base_dill", None)
            kk = getattr(k, "base_keys", None)
            if kd != None and kk != None:
                if base_dill == None:
                    base_dill = kd
                    base_keys = kk
                    base_kmods = getattr(k, "base_kmods", depset())
                if kd == base_dill:
                    k_unseeded = getattr(k, "unseeded_base_kmods", depset()).to_list()
                    if unseeded_candidates == None:
                        unseeded_candidates = {f.path: f for f in k_unseeded}
                    else:
                        keep = {f.path: True for f in k_unseeded}
                        unseeded_candidates = {
                            p: f
                            for p, f in unseeded_candidates.items()
                            if p in keep
                        }
    unseeded_base_kmods = depset(unseeded_candidates.values() if unseeded_candidates != None else [])
    link_dep_closure = dep_closure
    if base_dill != None and base_keys != None:
        user_kmod_paths = {
            f.path: True
            for k in dep_kernels
            if getattr(k, "base_dill", None) == None
            for f in k.transitive_kmods.to_list()
        }
        pruned_paths = {f.path: True for f in base_kmods.to_list()}
        for f in unseeded_base_kmods.to_list():
            if f.path not in user_kmod_paths:
                pruned_paths[f.path] = True
        if pruned_paths:
            link_dep_closure = depset(
                [f for f in dep_closure.to_list() if f.path not in pruned_paths],
                order = "postorder",
            )
    kernel_link_action(ctx, link_dep_closure, entry, output, base_keys = base_keys)
    return base_dill

_TEST_API_BASE_PACKAGES = {
    "async": True,
    "boolean_selector": True,
    "collection": True,
    "coverage": True,
    "file": True,
    "glob": True,
    "matcher": True,
    "meta": True,
    "package_config": True,
    "path": True,
    "pool": True,
    "source_maps": True,
    "source_span": True,
    "stack_trace": True,
    "stream_channel": True,
    "string_scanner": True,
    "term_glyph": True,
    "test": True,
    "test_api": True,
    "vm_service": True,
    "yaml": True,
}

def _kmod_pkg_name(kmod):
    name = kmod.basename
    return name[:-len(".kmod")] if name.endswith(".kmod") else name

def library_kernel_info(
        ctx,
        own_record,
        package_name,
        lib_root,
        own_srcs,
        opaque,
        target = "vm",
        platform_dill = None,
        libraries_json = None,
        libraries_platform = None,
        extra_libraries = [],
        scheme = STABLE_SCHEME,
        extra_frontend_flags = [],
        rule_deps = None):
    """The `DartKernelInfo` a `dart_library` provides.

    The module is declared only here. Nothing builds it until an executable links
    it, so a library reached only through AOT binaries compiles no module at all.

    Args:
      ctx: The `dart_library` rule or aspect context.
      own_record: The library's own `DartPackageInfo`, or None.
      package_name: The package the library declares.
      lib_root: The package's `lib_root`.
      own_srcs: The library's own `.dart` files.
      opaque: True when the sources arrive as one directory (`srcs_dir`), whose
        files are not known here.
      target: The `kernel_worker --target` name (`"vm"` by default).
      platform_dill: Optional platform `.dill` File override.
      libraries_json: Optional `libraries.json` File override.
      libraries_platform: Optional platform key in `libraries.json`.
      extra_libraries: Extra bare `dart:` library names available on the target.
      scheme: The multi-root URI scheme (`STABLE_SCHEME` by default).
      extra_frontend_flags: Extra flags forwarded to `kernel_worker`.
      rule_deps: Optional list of dependency targets (defaults to `ctx.attr.deps`).

    Returns:
      A `DartKernelInfo`.
    """
    enabled = ctx.attr._modular_kernel[BuildSettingInfo].value if hasattr(ctx.attr, "_modular_kernel") else True
    defines = global_dart_defines(ctx)
    if opaque or not enabled or any(["," in d for d in defines]):
        return no_kernel_module()
    tools = kernel_tools_for(ctx)
    if tools == None:
        return no_kernel_module()
    deps = rule_deps if rule_deps != None else ctx.attr.deps
    dep_kernels = dep_kernels_or_none(deps)
    if dep_kernels == None:
        return no_kernel_module()

    raw = depset(transitive = [dep[DartInfo].transitive_packages for dep in deps if DartInfo in dep]).to_list()
    records = ([own_record] if own_record != None else []) + raw
    modular = kernel_packages_consistent(records) and all([k.modular for k in dep_kernels])
    if not modular:
        return no_kernel_module()

    dep_closure = depset(
        order = "postorder",
        transitive = [k.transitive_kmods for k in dep_kernels],
    )
    dep_outline_closure = depset(
        order = "postorder",
        transitive = [k.transitive_koutlines for k in dep_kernels],
    )
    upstream_excluded = depset(transitive = [k.closure_excluded for k in dep_kernels])
    has_cross_pkg_cycle = False
    cross_pkg_srcs = (
        depset(own_srcs, transitive = [collect_transitive_srcs(deps)])
        if has_cross_pkg_cycle
        else depset(transitive = [k.cross_pkg_srcs for k in dep_kernels])
    )
    owned = depset(
        [(str(ctx.label), f.short_path) for f in own_srcs],
        transitive = [k.owned for k in dep_kernels],
    )
    edges = depset(
        [(str(ctx.label), str(dep.label)) for dep in deps],
        transitive = [k.edges for k in dep_kernels],
    )
    base_dill = None
    base_keys = None
    base_kmods = depset()
    unseeded_candidates = None
    for k in dep_kernels:
        kd = getattr(k, "base_dill", None)
        kk = getattr(k, "base_keys", None)
        if kd != None and kk != None:
            if base_dill == None:
                base_dill = kd
                base_keys = kk
                base_kmods = getattr(k, "base_kmods", depset())
            if kd == base_dill:
                k_unseeded = getattr(k, "unseeded_base_kmods", depset()).to_list()
                if unseeded_candidates == None:
                    unseeded_candidates = {f.path: f for f in k_unseeded}
                else:
                    keep = {f.path: True for f in k_unseeded}
                    unseeded_candidates = {
                        p: f
                        for p, f in unseeded_candidates.items()
                        if p in keep
                    }
    if base_dill != None and unseeded_candidates != None:
        non_base_kmod_paths = {
            f.path: True
            for k in dep_kernels
            if getattr(k, "base_dill", None) == None
            for f in k.transitive_kmods.to_list()
        }
        if non_base_kmod_paths:
            unseeded_candidates = {
                p: f
                for p, f in unseeded_candidates.items()
                if p not in non_base_kmod_paths
            }
    unseeded_base_kmods = depset(unseeded_candidates.values() if unseeded_candidates != None else [])
    if not own_srcs:
        # A façade: nothing to compile, but its dependencies' modules still link.
        return DartKernelInfo(
            kmod = None,
            koutline = None,
            transitive_kmods = dep_closure,
            transitive_koutlines = dep_outline_closure,
            modular = True,
            closure_excluded = upstream_excluded,
            cross_pkg_srcs = cross_pkg_srcs,
            owned = owned,
            edges = edges,
            base_dill = base_dill,
            base_keys = base_keys,
            base_kmods = base_kmods,
            unseeded_base_kmods = unseeded_base_kmods,
        )

    kmod = ctx.actions.declare_directory(ctx.label.name + ".kmod")
    koutline = ctx.actions.declare_directory(ctx.label.name + ".koutline")
    sources = [
        struct(uri = library_source_uri(package_name, lib_root, f.short_path), file = f)
        for f in own_srcs
    ]
    excluded = kernel_module_action(
        ctx,
        tools,
        sources,
        first_per_package(records),
        dep_outline_closure,
        kmod,
        koutline = koutline,
        defines = defines,
        exclude_non_sources = True,
        droppable = True,
        closure_excluded = upstream_excluded,
        target = target,
        platform_dill = platform_dill,
        libraries_json = libraries_json,
        libraries_platform = libraries_platform,
        extra_libraries = extra_libraries,
        scheme = scheme,
        extra_frontend_flags = extra_frontend_flags,
    )
    if package_name == "test" and target == "vm" and hasattr(ctx.executable, "_kernel_link"):
        base_dill = ctx.actions.declare_file(ctx.label.name + ".base.dill")
        base_keys = ctx.actions.declare_file(ctx.label.name + ".base.keys")
        seeded_dep_kmods = [
            k
            for k in dep_closure.to_list()
            if _kmod_pkg_name(k) in _TEST_API_BASE_PACKAGES
        ]
        seed_kmods = [kmod] + seeded_dep_kmods
        unseeded_kmods = [
            k
            for k in dep_closure.to_list()
            if _kmod_pkg_name(k) not in _TEST_API_BASE_PACKAGES
        ]
        kernel_link_action(
            ctx,
            dep_closure,
            entry = None,
            output = base_dill,
            seed_modules = seed_kmods,
            write_keys = base_keys,
        )
        base_kmods = depset(seeded_dep_kmods)
        unseeded_base_kmods = depset(unseeded_kmods)
    return DartKernelInfo(
        kmod = kmod,
        koutline = koutline,
        transitive_kmods = depset(order = "postorder", direct = [kmod], transitive = [dep_closure]),
        transitive_koutlines = depset(order = "postorder", direct = [koutline], transitive = [dep_outline_closure]),
        modular = True,
        closure_excluded = depset(direct = [excluded], transitive = [upstream_excluded]),
        cross_pkg_srcs = cross_pkg_srcs,
        owned = owned,
        edges = edges,
        base_dill = base_dill,
        base_keys = base_keys,
        base_kmods = base_kmods,
        unseeded_base_kmods = unseeded_base_kmods,
    )

def _dart_kernel_module_aspect_impl(target, ctx):
    if DartKernelInfo in target:
        return []
    if DartInfo not in target:
        return [no_kernel_module()]
    library = getattr(ctx.rule.attr, "library", None)
    if library != None and DartKernelInfo in library:
        return [library[DartKernelInfo]]

    dart_info = target[DartInfo]
    package_name = dart_info.package_name
    lib_root = dart_info.lib_root
    own_record = own_package_record(dart_info)
    srcs_dir = getattr(ctx.rule.attr, "srcs_dir", None)
    has_srcs_attr = hasattr(ctx.rule.attr, "srcs")
    own_srcs = getattr(ctx.rule.files, "srcs", [])
    rule_deps = getattr(ctx.rule.attr, "deps", [])
    if type(rule_deps) != "list":
        rule_deps = [rule_deps]

    opaque = bool(srcs_dir)
    if not has_srcs_attr and dart_info.transitive_srcs.to_list() != [] and len(rule_deps) == 0:
        opaque = True
    prefix = package_lib_prefix(lib_root)
    if own_srcs and (not package_name or own_record == None or any([not f.short_path.startswith(prefix) for f in own_srcs])):
        opaque = True

    return [
        library_kernel_info(
            ctx,
            own_record,
            package_name,
            lib_root,
            own_srcs,
            opaque = opaque,
            rule_deps = rule_deps,
        ),
    ]

dart_kernel_module_aspect = aspect(
    implementation = _dart_kernel_module_aspect_impl,
    attr_aspects = ["deps", "library"],
    attrs = KERNEL_MODULE_ATTRS | EXTRA_DART_DEFINES_ATTR,
    toolchains = MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles each `dart_library` in a modular executable's or test's closure to a `.kmod` directory.",
)
