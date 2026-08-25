"""Shared utilities for Dart rules."""

load("//dart:providers.bzl", "CODE_ASSET_LINK_MODES", "DartAnalysisOptionsInfo", "DartAnalyzableInfo", "DartInfo")
load("//dart/private:dart_info.bzl", "derived_package_info")
load("//dart/private:source_set.bzl", "needs_source_assembly", "package_for")

# Official Bazel bash runfiles v3 initialization boilerplate.
# Sources runfiles.bash which provides rlocation() for cross-platform
# runfile resolution (directory, manifest, and .exe.runfiles).
# See: https://github.com/bazelbuild/rules_shell/blob/main/shell/runfiles/runfiles.bash
BASH_RUNFILES_INIT = """\
# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---"""

# Private attribute that makes the bash runfiles library available in the
# runfiles tree of rules that generate bash launcher scripts.
BASH_RUNFILES_ATTR = {
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
}

# Private attribute for detecting Windows at analysis time (for .exe extension).
WINDOWS_CONSTRAINT_ATTR = {
    "_windows_constraint": attr.label(
        default = "@platforms//os:windows",
    ),
}

# Private attributes for resolving the Dart code-asset ABI string
# (`<os>_<arch>`, e.g. `macos_arm64`) from the target platform at analysis
# time. `DartSdkInfo.target_os/target_arch` are empty for native/host
# toolchains (the only ones a test runs under), so we probe constraints
# directly — the idiomatic pattern in this repo (see WINDOWS_CONSTRAINT_ATTR).
#
# Attrs are named after the DART arch, not the Bazel constraint value: Dart's
# `arm64` is Bazel's `aarch64`, its `x64` is `x86_64`, and its `arm` is `armv7`.
# The set covers every CPU rules_dart registers a toolchain for, so a user who
# brings their own cc toolchain for one of them is not blocked here.
DART_ABI_CONSTRAINT_ATTRS = {
    "_os_macos": attr.label(default = "@platforms//os:macos"),
    "_os_linux": attr.label(default = "@platforms//os:linux"),
    "_os_windows": attr.label(default = "@platforms//os:windows"),
    "_cpu_arm64": attr.label(default = "@platforms//cpu:aarch64"),
    "_cpu_x64": attr.label(default = "@platforms//cpu:x86_64"),
    "_cpu_riscv64": attr.label(default = "@platforms//cpu:riscv64"),
    "_cpu_arm": attr.label(default = "@platforms//cpu:armv7"),
}

def runfiles_path(f, workspace_name):
    """Convert a File to its runfiles-relative path.

    Args:
        f: A File object.
        workspace_name: The workspace name (ctx.workspace_name).

    Returns:
        The runfiles-relative path string.
    """
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return workspace_name + "/" + f.short_path

def create_test_executable(ctx, tool, env):
    """Create a test executable by symlinking a pre-compiled tool binary.

    Handles .exe extension on Windows. Returns the executable file and a
    RunEnvironmentInfo provider for passing configuration via env vars.

    Args:
        ctx: The rule context.
        tool: The pre-compiled tool target (from a cfg="exec" attr).
        env: Dict of environment variable names to values for RunEnvironmentInfo.

    Returns:
        Tuple of (executable File, RunEnvironmentInfo provider, tool runfiles).
    """
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)

    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    env_info = testing.TestEnvironment(env)
    tool_runfiles = tool[DefaultInfo].default_runfiles

    return executable, env_info, tool_runfiles

def package_code_assets(pkg):
    """Code assets declared on a `DartPackageInfo`, tolerating older producers.

    `code_assets` is optional in the same sense `language_version` is: a
    `DartPackageInfo` built against a rules_dart that predates the field omits
    it, and such a record keeps working — it simply contributes no assets.
    `//dart/tests/no_lv_fixture` pins that tolerance, emitting a record with
    only `package_name` and `lib_root`.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      Tuple of `DartCodeAssetInfo`; empty when the field is absent.
    """
    return pkg.code_assets if hasattr(pkg, "code_assets") else ()

def collect_code_asset_files(deps):
    """Merges `DartInfo.transitive_code_asset_files` across deps.

    Args:
      deps: List of targets providing `DartInfo`.

    Returns:
      `depset[File]` of every transitive code asset's dynamic library.
    """
    return depset(transitive = [
        dep[DartInfo].transitive_code_asset_files
        for dep in deps
        if hasattr(dep[DartInfo], "transitive_code_asset_files")
    ])

def collect_transitive_code_assets(deps):
    """Collects `DartCodeAssetInfo` from every package reachable through deps.

    Args:
      deps: List of targets providing `DartInfo`.

    Returns:
      List of `DartCodeAssetInfo`, in dependency order, with duplicates from
      diamonds left in place — callers dedup by asset id.
    """
    assets = []
    for pkg in collect_packages(deps):
        assets.extend(list(package_code_assets(pkg)))
    return assets

def own_package_record(info):
    """Returns the `DartPackageInfo` for the package a `DartInfo` itself owns.

    A `DartInfo` names its own package by `package_name`/`lib_root` but does
    not carry that package's record: the record sits in `transitive_packages`
    beside every dependency's. Both fields are the key, not the name alone —
    one `package_name` legitimately maps to several `lib_root`s (a package
    split across targets; two pub hubs each supplying `meta`), so matching on
    the name would sometimes return a dependency's record instead of this
    target's, and with it a dependency's language version.

    Args:
      info: A `DartInfo`.

    Returns:
      The matching `DartPackageInfo`, or `None` when the target contributes no
      package of its own (`dart_info_no_package`) or no record matches.
    """
    if not info.package_name:
        return None
    for pkg in info.transitive_packages.to_list():
        if pkg.package_name == info.package_name and pkg.lib_root == info.lib_root:
            return pkg
    return None

def collect_packages(deps):
    """Collect unique DartPackageInfo providers from transitive deps.

    Flattens the merged transitive depset exactly once (package metadata is
    inspected per-entry for dedup, so a flatten is unavoidable here — but it
    is bounded by the package count, not the source-file count).

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        List of unique DartPackageInfo providers in dependency order.
    """
    return merge_package_records(
        depset(transitive = [dep[DartInfo].transitive_packages for dep in deps]).to_list(),
    )

def merge_package_records(merged):
    """Dedups package records by name, unioning their code assets.

    One `package_name` can legitimately appear with several `lib_root`s:

      * a package split across `dart_library` targets — the case
        `colocate_packages` exists to serve; and
      * a package supplied independently by two pub hubs, e.g. rules_flutter's
        `flutter.pub()` and rules_dart's `pub.from_lock()` both generating a
        spoke for `ffi`.

    So the first record wins for source resolution, as it always has. Code
    assets are the exception: dropping a later record's assets would silently
    lose a native library, and the failure would surface at runtime as an
    unresolved `@Native` symbol. Union them instead, and let
    `resolve_code_assets` fail later if — and only if — two assets genuinely
    claim one id, which is the case the Dart VM cannot resolve either.

    Split out from `collect_packages` because it is pure: everything here is a
    function of the record list, which makes the dedup and union rules
    directly testable without synthesising `DartInfo`-bearing targets.

    Args:
        merged: List of DartPackageInfo, with duplicates, in dependency order.

    Returns:
        List of unique DartPackageInfo providers in dependency order.
    """
    packages = []
    index_by_name = {}
    for pkg in merged:
        index = index_by_name.get(pkg.package_name)
        if index == None:
            index_by_name[pkg.package_name] = len(packages)
            packages.append(pkg)
        elif package_code_assets(pkg):
            kept = packages[index]

            # Only the assets merge; every other field stays the kept record's.
            # That includes `has_unreplaced_hook`, so two hubs supplying one
            # package can disagree about whether the hook was replaced and
            # dependency order decides which answer survives. Recorded rather
            # than quietly changed: picking the other one is a semantic call
            # about what a replaced hook means for a package reached twice.
            packages[index] = derived_package_info(
                kept,
                code_assets = package_code_assets(kept) + package_code_assets(pkg),
            )
    return packages

def analyze_operand(ctx):
    """Returns the target a `dart_analyze_test` / `dart_fix` was pointed at.

    Both rules name the operand `target` and still answer to the older `lib`.
    Neither attribute can be `mandatory` while the other exists, so the
    missing-attribute error Bazel used to raise for `lib` has to be raised here
    instead — and with it the both-set case, where picking one silently would
    analyze something the BUILD file did not ask for.

    Args:
      ctx: The rule context (must declare both `target` and `lib`).

    Returns:
      The chosen target.
    """
    if ctx.attr.target and ctx.attr.lib:
        fail(("%s: set either `target` or `lib`, not both. `lib` is the " +
              "deprecated spelling of `target`; drop it.") % ctx.label)
    if ctx.attr.target:
        return ctx.attr.target
    if ctx.attr.lib:
        return ctx.attr.lib
    fail(("%s: missing `target` — name the `dart_library`, `dart_binary` or " +
          "`dart_test` whose Dart sources to analyze.") % ctx.label)

def analyzable_closure(target):
    """Normalizes an analyze/fix operand to the closure and the loose sources.

    `dart_analyze_test` and `dart_fix` accept either provider — `DartInfo` from
    a library, `DartAnalyzableInfo` from an executable — and this is the single
    place that OR is resolved, so neither rule has to branch and the two cannot
    drift into disagreeing about what "the sources to analyze" means.

    Args:
      target: A target providing `DartAnalyzableInfo` or `DartInfo`.

    Returns:
      `struct(dart_info, srcs)` — the dependency closure, and the target's own
      package-less entrypoint sources (empty for a library, whose every source
      is already inside the closure).
    """
    if DartAnalyzableInfo in target:
        analyzable = target[DartAnalyzableInfo]
        return struct(
            dart_info = analyzable.dart_info,
            srcs = analyzable.srcs.to_list(),
        )
    return struct(dart_info = target[DartInfo], srcs = [])

def analysis_options_closure(options_attr):
    """Normalizes an `options` attribute to the closure its `include:`s need.

    Every rule that stages a project for an SDK tool — `dart_analyze_test`,
    `dart_fix`, `dart_format_test` — accepts the same three shapes: unset, a
    bare `.yaml` label, and a `dart_analysis_options` target. Only the third
    carries packages, because only a `package:` URI needs resolving; this is
    the single place that distinction is made, so the rules cannot drift into
    staging different closures for the same options file.

    The packages are for resolution alone. Callers merge them into the list
    that builds `package_config.json` and stage the files, but they never enter
    the analyzed target's own `DartInfo` — see `dart_analysis_options`.

    Args:
      options_attr: The rule's `ctx.attr.options` (may be `None`).

    Returns:
      `struct(packages, files)` — `DartPackageInfo` records the includes may
      reference, and the files of those packages to stage. Both empty unless
      the attribute is a `dart_analysis_options` target.
    """
    if not options_attr or DartAnalysisOptionsInfo not in options_attr:
        return struct(packages = [], files = [])
    opts = options_attr[DartAnalysisOptionsInfo]
    return struct(
        packages = opts.packages,
        files = (
            opts.transitive_srcs.to_list() + opts.transitive_resources.to_list()
        ),
    )

def noop_test_executable(ctx, tool):
    """Symlinks the do-nothing binary as a test rule's executable.

    `dart_analyze_test` and `dart_format_test` both decide their verdict in a
    build action: when the action fails the build fails, and nothing is left
    for the test binary to check. Both must still *be* tests, so both hand
    Bazel the same pass-through executable.

    Args:
      ctx: The rule context (must carry `WINDOWS_CONSTRAINT_ATTR`).
      tool: The `//dart/private/tools:noop` target.

    Returns:
      `struct(executable, runfiles)` — the declared symlink and the tool's own
      runfiles, for the caller to merge with whatever stamp it produced.
    """
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    return struct(
        executable = executable,
        runfiles = tool[DefaultInfo].default_runfiles,
    )

def writable_home_env(dart, beside):
    """The environment an SDK build action needs to have a writable home.

    Windows `dart.exe` takes a POSIX `/tmp` literally and crashes, so it is
    pointed at a directory that exists on the platform running it instead.

    Args:
      dart: The SDK's `dart` File, whose basename identifies the platform.
      beside: A File whose directory serves as the Windows home.

    Returns:
      A dict for `ctx.actions.run(env = ...)`.
    """
    if dart.basename.endswith(".exe"):
        return {"USERPROFILE": beside.dirname, "LOCALAPPDATA": beside.dirname}
    return {"HOME": "/tmp"}

def relative_path(from_dir, to_dir):
    """Compute the relative path from one directory to another.

    Both paths must be in the same coordinate system (e.g., both exec-root-relative).

    Args:
        from_dir: The starting directory path.
        to_dir: The target directory path.

    Returns:
        A relative path string from from_dir to to_dir.
    """
    from_parts = from_dir.split("/") if from_dir else []
    to_parts = to_dir.split("/") if to_dir else []

    # Find common prefix length
    common = 0
    for i in range(min(len(from_parts), len(to_parts))):
        if from_parts[i] != to_parts[i]:
            break
        common = i + 1

    ups = len(from_parts) - common
    remaining = to_parts[common:]
    parts = [".."] * ups + remaining
    return "/".join(parts) if parts else "."

def check_single_root_package(packages):
    """Checks that at most one package claims the empty (root) `lib_root`.

    Two or more empty-lib_root packages are ambiguous: the empty-prefix match
    would race to claim any `lib/`-prefixed source.

    Args:
        packages: List of DartPackageInfo providers.

    Returns:
        An error message string when more than one package has an empty
        `lib_root`, else `None`.
    """
    root_names = [pkg.package_name for pkg in packages if not pkg.lib_root]
    if len(root_names) > 1:
        return (
            "Multiple packages declare an empty `lib_root`: %s. Each " +
            "Bazel build graph can only attribute `lib/...` sources to " +
            "one root package."
        ) % ", ".join(root_names)
    return None

def resolve_package_roots(packages, all_srcs):
    """Match packages to source files, returning exec-root-relative roots.

    Matches using short_path (same coordinate system as lib_root),
    then derives the exec-root path from the matched File.path.

    Two or more packages with an empty `lib_root` are ambiguous — the
    empty-prefix match would race to claim any `lib/`-prefixed source.
    Fail loud if detected; callers should not be building transitive
    `DartInfo` graphs with colliding root assignments.

    Args:
        packages: List of DartPackageInfo providers.
        all_srcs: List of File objects from the transitive source closure.

    Returns:
        Dict mapping package_name to exec-root-relative package root path.
    """
    err = check_single_root_package(packages)
    if err:
        fail(err)

    roots = {}
    for src in all_srcs:
        for pkg in packages:
            if pkg.package_name in roots:
                continue
            if not pkg.lib_root:
                # Root package: sources are directly under lib/. Safe because
                # the earlier check guarantees at most one such package.
                if src.short_path.startswith("lib/") or src.short_path == "lib":
                    suffix = src.short_path
                    exec_root = src.path[:len(src.path) - len(suffix)]
                    if exec_root.endswith("/"):
                        exec_root = exec_root[:-1]
                    roots[pkg.package_name] = exec_root
            elif src.short_path.startswith(pkg.lib_root + "/") or \
                 (src.is_directory and src.short_path == pkg.lib_root):
                suffix = src.short_path[len(pkg.lib_root):]
                roots[pkg.package_name] = src.path[:len(src.path) - len(suffix)]
    return roots

def generate_package_config(packages, all_srcs, config_file):
    """Generate package_config.json content using short_path-based lib_root.

    Resolves exec-root paths from source files, then computes relative
    rootUri from config_file's dirname to each package's exec-root location.

    Args:
        packages: List of DartPackageInfo providers.
        all_srcs: List of File objects from the transitive source closure.
        config_file: The output File for package_config.json (used for dirname).

    Returns:
        String content of the package_config.json file.
    """
    if not packages:
        return '{"configVersion": 2, "packages": []}\n'

    exec_roots = resolve_package_roots(packages, all_srcs)
    config_dir = config_file.dirname

    entries = []
    for pkg in packages:
        exec_root = exec_roots.get(pkg.package_name)
        if exec_root != None:
            root_uri = relative_path(config_dir, exec_root)
        elif not pkg.lib_root:
            # Root package with no sources found — fall back to depth-based
            root_uri = relative_path(config_dir, "")
        else:
            # Package contributes no .dart sources to the transitive closure.
            # Two legitimate cases hit this:
            #   1. asset/font-only pub deps (e.g. `cupertino_icons`) pulled
            #      into a Flutter app — assets ride through other providers,
            #      not `package:` URIs;
            #   2. an aggregate `dart_library(srcs = [])` façade that exists
            #      only to re-export its deps.
            # Either way no consumer needs a `rootUri` for this package. If
            # anything *does* import `package:<name>/…`, the Dart frontend
            # reports a localized URI-not-found at the import — clearer than
            # failing the whole package_config build here.
            continue
        lv = ""
        if hasattr(pkg, "language_version") and pkg.language_version:
            lv = ', "languageVersion": "{lv}"'.format(lv = pkg.language_version)
        entries.append(
            '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"{lv}}}'.format(
                name = pkg.package_name,
                root_uri = root_uri,
                lv = lv,
            ),
        )
    return '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )

def _exec_root_of(f):
    """Returns the exec-root-relative dir that, prepended to `f.short_path`, yields `f.path`.

    For a source-tree file this is `""` (the exec root itself); for a generated
    file it is its `bazel-out/<cfg>/bin`-style output dir.
    """
    p = f.path
    sp = f.short_path
    root = p[:len(p) - len(sp)] if sp and p.endswith(sp) else p
    if root.endswith("/"):
        root = root[:-1]
    return root

def generate_dev_package_config(packages, all_srcs, config_file, scheme = "org-dartlang-app"):
    """`generate_package_config` variant for live hot reload of codegen apps.

    A package whose hand-written and generated sources straddle the source tree
    and `bazel-out` would, under the normal generator, get a `rootUri` pointing
    at the frozen assembled (`*.pkgsrcs`) directory — so a dev tool reading it
    sees stale generated output and never sees live source edits. Instead, this
    emits a `<scheme>:///<lib_root>` `rootUri` for each such package and reports
    the filesystem roots the frontend_server must search (`--filesystem-root`,
    `--filesystem-scheme`) to resolve those scheme URIs across BOTH the live
    source tree and the generated `bazel-out` outputs. Non-assembled packages
    (pub deps, pure source packages) keep their normal relative `rootUri` —
    the frontend_server resolves a mix of scheme and relative `rootUri`s.

    Args:
        packages: List of DartPackageInfo providers (pre-colocation, so the app
            package still has its real `lib_root`).
        all_srcs: List of File objects (pre-colocation, so `is_source` is intact).
        config_file: The output File for the dev package_config.json (for dirname).
        scheme: Filesystem scheme for assembled packages' rootUris.

    Returns:
        struct(content, filesystem_roots, scheme, generated_source_paths, generated_source_uris, source_packages):
          content: package_config.json text.
          filesystem_roots: deduped exec-root-relative dirs for `--filesystem-root`
            (source roots first, then generated roots); empty when nothing needed
            assembly (then the config equals the normal one and no scheme is used).
          scheme: the filesystem scheme (meaningful only when roots are non-empty).
          generated_source_paths: exec-root-relative paths of the generated files
            in assembled packages — the dev tool re-stats these after a rebuild to
            add changed ones to the reload invalidation set.
          generated_source_uris: the `package:` URI for each entry in
            generated_source_paths, index-aligned, so the dev tool can map a
            changed file straight to the URI to invalidate without re-deriving it.
          source_packages: (name, lib_root) for each package contributing a
            first-party (editable, main-repo) source file — the dev tool's
            path->package: map for live edits. Excludes pub/external deps and
            generated-only packages.
    """
    if not packages:
        return struct(
            content = '{"configVersion": 2, "packages": []}\n',
            filesystem_roots = [],
            scheme = scheme,
            generated_source_paths = [],
            generated_source_uris = [],
            source_packages = [],
        )

    by_pkg = {}
    for f in all_srcs:
        name = package_for(f.short_path, packages)
        if name == None:
            continue
        by_pkg.setdefault(name, []).append(f)

    exec_roots = resolve_package_roots(packages, all_srcs)
    config_dir = config_file.dirname

    # First-party source packages (name, lib_root) the dev tool can map a live
    # edit back to: any package contributing an `is_source` file that lives in
    # the main repo (short_path not under `external/` or `../<repo>`). Excludes
    # pub/external deps (not editable, never watched) and generated-only
    # packages. `lib_root` is short_path-relative, i.e. workspace-relative, so
    # the dev tool resolves a path to `package:<name>/<rel>` without inverting
    # rootUris — see the dev tool's PackageUriResolver.
    source_packages = []
    for pkg in packages:
        for f in by_pkg.get(pkg.package_name, []):
            if (f.is_source and
                not f.short_path.startswith("external/") and
                not f.short_path.startswith("../")):
                source_packages.append((pkg.package_name, pkg.lib_root))
                break

    source_roots = []
    generated_roots = []
    generated_source_paths = []
    generated_source_uris = []
    entries = []
    for pkg in packages:
        files = by_pkg.get(pkg.package_name, [])
        if needs_source_assembly(files):
            root_uri = "{scheme}:///{lib_root}".format(
                scheme = scheme,
                lib_root = pkg.lib_root,
            )
            lib_prefix = (pkg.lib_root + "/lib/") if pkg.lib_root else "lib/"
            for f in files:
                er = _exec_root_of(f)
                if f.is_source:
                    if er not in source_roots:
                        source_roots.append(er)
                else:
                    if er not in generated_roots:
                        generated_roots.append(er)

                    # Pair each generated file's exec path with its `package:`
                    # URI so the dev tool can invalidate it on reload after a
                    # rebuild — no path→URI inference needed downstream.
                    if f.short_path.startswith(lib_prefix):
                        generated_source_paths.append(f.path)
                        generated_source_uris.append("package:{name}/{rel}".format(
                            name = pkg.package_name,
                            rel = f.short_path[len(lib_prefix):],
                        ))
        else:
            exec_root = exec_roots.get(pkg.package_name)
            if exec_root != None:
                root_uri = relative_path(config_dir, exec_root)
            elif not pkg.lib_root:
                root_uri = relative_path(config_dir, "")
            else:
                continue
        lv = ""
        if hasattr(pkg, "language_version") and pkg.language_version:
            lv = ', "languageVersion": "{lv}"'.format(lv = pkg.language_version)
        entries.append(
            '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"{lv}}}'.format(
                name = pkg.package_name,
                root_uri = root_uri,
                lv = lv,
            ),
        )
    content = '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )
    return struct(
        content = content,
        filesystem_roots = source_roots + generated_roots,
        scheme = scheme,
        generated_source_paths = generated_source_paths,
        generated_source_uris = generated_source_uris,
        source_packages = source_packages,
    )

def generate_package_config_content(packages, prefix):
    """Generate package_config.json content string (prefix-based).

    Simple version for staging-directory contexts where the relationship between
    the config file and package roots is known statically (e.g., dart_analyze
    where config is at .dart_tool/ and packages are at ../<lib_root>).

    Args:
        packages: List of DartPackageInfo providers.
        prefix: Path prefix to prepend to each package's lib_root for rootUri.

    Returns:
        String content of the package_config.json file.
    """
    if not packages:
        return '{"configVersion": 2, "packages": []}\n'

    entries = []
    for pkg in packages:
        root_uri = prefix + "/" + pkg.lib_root if pkg.lib_root else prefix
        lv = ""
        if hasattr(pkg, "language_version") and pkg.language_version:
            lv = ', "languageVersion": "{lv}"'.format(lv = pkg.language_version)
        entries.append(
            '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"{lv}}}'.format(
                name = pkg.package_name,
                root_uri = root_uri,
                lv = lv,
            ),
        )
    return '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )

def collect_transitive_srcs(deps):
    """Collect all transitive source files from DartInfo deps.

    Returns a depset so consumers can feed action inputs / runfiles without
    flattening. Callers that genuinely inspect per-file paths (package
    colocation, package_config root resolution) call `.to_list()` exactly
    once at that point.

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        Depset of Files from the transitive source closure.
    """
    return depset(transitive = [dep[DartInfo].transitive_srcs for dep in deps])

def collect_transitive_resources(deps):
    """Collect all transitive `resources` files from DartInfo deps.

    The sibling of `collect_transitive_srcs`, for the non-Dart files a package
    ships inside `lib/`. Kept a separate call rather than folded into that one
    so every consumer has to say which of the two it means: staging a package
    whole wants both, feeding the compiler wants only the sources.

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        Depset of Files from the transitive resource closure.
    """
    return depset(transitive = [dep[DartInfo].transitive_resources for dep in deps])

def sdk_path_from_dart(dart_file):
    """Returns the SDK installation root by stripping `/bin/dart` from a dart File path.

    AOT-compiled shims pass this via `--sdk-path` so the analyzer's
    `AnalysisContextCollection` can locate the SDK's libraries.

    Args:
      dart_file: The toolchain's `dart` executable File.

    Returns:
      The SDK root path string.
    """
    p = dart_file.path
    for suffix in ("/bin/dart", "/bin/dart.exe"):
        if p.endswith(suffix):
            return p[:-len(suffix)]
    return p

def synth_package_config(ctx, library_deps):
    """Synthesises a `package_config.json` from `dart_library` targets.

    Args:
      ctx: The rule context (used to declare the output file).
      library_deps: List of `dart_library` targets to merge.

    Returns:
      `(package_config_file, transitive_srcs_depset)`, or `(None, None)`
      when `library_deps` is empty. The caller is expected to add both to
      the action's `inputs` (the depset flattens lazily at execution time).
    """
    if not library_deps:
        return None, None
    packages = collect_packages(library_deps)
    transitive_srcs = collect_transitive_srcs(library_deps)
    package_config = ctx.actions.declare_file(
        ctx.label.name + ".package_config.json",
    )

    # generate_package_config needs a list of File (not a depset) because
    # it performs per-file path matching. Materialising here is bounded
    # by the dep graph size for this one target, not by the action count.
    content = generate_package_config(
        packages,
        transitive_srcs.to_list(),
        package_config,
    )
    ctx.actions.write(output = package_config, content = content)
    return package_config, transitive_srcs

# --- Native code-asset (gen_kernel --native-assets) helpers ---
#
# SKELETON STUBS: signatures exist so `dart_test`/`dart_binary` load and the
# unit tests fail on assertions rather than missing symbols. Implemented in a
# follow-up edit.

def target_dart_abi(ctx):
    """Returns the Dart code-asset ABI string for the target platform.

    Format `<os>_<arch>` (e.g. `macos_arm64`, `linux_x64`, `windows_x64`,
    `linux_riscv64`, `linux_arm`), matching
    `kTargetOperatingSystemName_kTargetArchitectureName` in the VM
    (`runtime/vm/ffi/native_assets.cc`) and the `TARGET_PLATFORMS` table in
    `toolchains_repo.bzl`. Reads `DART_ABI_CONSTRAINT_ATTRS` constraints.

    Args:
      ctx: The rule context (must spread `DART_ABI_CONSTRAINT_ATTRS` in attrs).

    Returns:
      The `<os>_<arch>` ABI string.
    """
    if ctx.target_platform_has_constraint(ctx.attr._os_macos[platform_common.ConstraintValueInfo]):
        os = "macos"
    elif ctx.target_platform_has_constraint(ctx.attr._os_linux[platform_common.ConstraintValueInfo]):
        os = "linux"
    elif ctx.target_platform_has_constraint(ctx.attr._os_windows[platform_common.ConstraintValueInfo]):
        os = "windows"
    else:
        fail("%s: code_assets require a macos/linux/windows target OS." % ctx.label)
    if ctx.target_platform_has_constraint(ctx.attr._cpu_arm64[platform_common.ConstraintValueInfo]):
        arch = "arm64"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_x64[platform_common.ConstraintValueInfo]):
        arch = "x64"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_riscv64[platform_common.ConstraintValueInfo]):
        arch = "riscv64"
    elif ctx.target_platform_has_constraint(ctx.attr._cpu_arm[platform_common.ConstraintValueInfo]):
        arch = "arm"
    else:
        fail(("%s: code_assets require an aarch64, x86_64, riscv64 or armv7 " +
              "target CPU (Dart has no code-asset ABI name for others). Every " +
              "CPU rules_dart registers a toolchain for is covered; this fires " +
              "for a platform supplied by a downstream module.") % ctx.label)

    # The OS and CPU probes are independent, so a user-declared platform can
    # produce a combination Dart never ships (e.g. `macos_riscv64`). That hole
    # predates the riscv64/armv7 entries — `macos_arm` was already reachable —
    # and it surfaces as a `native_assets.yaml` key the VM never looks up
    # rather than as a build error. Not worth a validity table.
    return os + "_" + arch

def find_sdk_kernel_tools(dart_sdk_info):
    """Locates the gen_kernel toolchain files within the SDK tree.

    Returns a struct with the `dartaotruntime` executable, the
    `gen_kernel_aot.dart.snapshot`, and `vm_platform_strong.dill` Files,
    found by exact path under the SDK root within `dart_sdk_info.tool_files`.

    Args:
      dart_sdk_info: The `DartSdkInfo` from the toolchain.

    Returns:
      `struct(dartaotruntime, gen_kernel_snapshot, platform_dill)` of Files.
    """
    sdk_root = sdk_path_from_dart(dart_sdk_info.dart)
    wanted = {
        "dartaotruntime": [
            sdk_root + "/bin/dartaotruntime",
            sdk_root + "/bin/dartaotruntime.exe",
        ],
        "gen_kernel_snapshot": [sdk_root + "/bin/snapshots/gen_kernel_aot.dart.snapshot"],
        "platform_dill": [sdk_root + "/lib/_internal/vm_platform_strong.dill"],
    }
    found = {}

    # Analysis-time path probe for 3 files; a legitimate one-time flatten.
    for f in dart_sdk_info.tool_files.to_list():
        for key, paths in wanted.items():
            if f.path in paths:
                found[key] = f
    for key in wanted:
        if key not in found:
            fail(("find_sdk_kernel_tools: could not locate %s under SDK root " +
                  "%r (Dart %s). The SDK layout may have changed across " +
                  "versions; native code-asset support needs the AOT " +
                  "gen_kernel snapshot.") %
                 (key, sdk_root, dart_sdk_info.version))
    return struct(
        dartaotruntime = found["dartaotruntime"],
        gen_kernel_snapshot = found["gen_kernel_snapshot"],
        platform_dill = found["platform_dill"],
    )

# Code-asset link mode -> the Dart VM path type it maps to
# (`runtime/vm/ffi/native_assets.cc`), and which value supplies the payload:
# "" means the path type stands alone.
#
# `dynamic_loading_bundle` maps to `relative` because `dart_binary`/`dart_test`
# stage the library in runfiles next to the dill. An application *bundler*
# such as rules_flutter maps the same link mode to `absolute` against its own
# bundle layout — the two are not interchangeable, which is why this table
# lives here and not next to `CODE_ASSET_LINK_MODES`.
_VM_PATH_TYPE = {
    "dynamic_loading_bundle": ("relative", "library"),
    "dynamic_loading_system": ("system", "system_uri"),
    "dynamic_loading_executable": ("executable", ""),
    "dynamic_loading_process": ("process", ""),
}

# Load-time completeness check: the table must cover the vocabulary exactly, so
# a link mode cannot be accepted by `dart_code_asset` and then go unhandled
# here. Without it the gap would surface at analysis time, in whichever
# consumer first used the new mode.
#
# Written as an if-*expression* bound to a name because Starlark allows neither
# a top-level `if` statement nor a top-level bare expression. The binding is
# never read; evaluating it at load time is the entire point.
_UNMAPPED_LINK_MODES = [m for m in CODE_ASSET_LINK_MODES if m not in _VM_PATH_TYPE]

# buildifier: disable=unused-variable
_VM_PATH_TYPE_IS_TOTAL = fail(
    "common.bzl: _VM_PATH_TYPE has no entry for link mode(s) %s. Every mode in " %
    ", ".join(_UNMAPPED_LINK_MODES) +
    "CODE_ASSET_LINK_MODES must map to a Dart VM path type.",
) if _UNMAPPED_LINK_MODES else True

def native_assets_path_list(label, link_mode, relative_lib_path, system_uri):
    """Returns the VM path-list for one code asset, per its link mode.

    Args:
      label: The consuming target's label, for error messages.
      link_mode: One of `CODE_ASSET_LINK_MODES`.
      relative_lib_path: Path to the library relative to the dill, for
        `dynamic_loading_bundle`.
      system_uri: The system library URI, for `dynamic_loading_system`.

    Returns:
      List of strings forming the asset's JSON path-list.
    """
    mapping = _VM_PATH_TYPE.get(link_mode)
    if mapping == None:
        fail("%s: unsupported code-asset link_mode %r. Expected one of: %s." %
             (label, link_mode, ", ".join(CODE_ASSET_LINK_MODES)))
    path_type, payload = mapping
    if payload == "library":
        return [path_type, relative_lib_path]
    if payload == "system_uri":
        return [path_type, system_uri]
    return [path_type]

def check_unreplaced_hooks(label, packages):
    """Checks that no package in the closure has an unreplaced build hook.

    A pub package shipping `hook/build.dart` builds native libraries at
    `pub get` time. rules_dart cannot run that hook, so without a Bazel
    replacement the package's `@Native` bindings resolve to nothing — the
    manifest is simply missing an entry, and the failure surfaces at runtime
    as "couldn't resolve native function", with nothing pointing at the cause.

    Deliberately checked here rather than when the spoke repo is generated:
    `pub.from_lock()` materialises the whole lock file, so failing at
    generation would fail on packages nothing depends on and on platforms
    where the hook is irrelevant. Only a package actually reached by a binary
    or test is a problem, and only here is the depending target known.

    Args:
      label: The consuming target's label.
      packages: List of `DartPackageInfo` in the transitive closure.

    Returns:
      An error message string, or `None`.
    """
    offenders = [
        pkg
        for pkg in packages
        if hasattr(pkg, "has_unreplaced_hook") and pkg.has_unreplaced_hook
    ]
    if not offenders:
        return None
    lines = [
        "  - %s (%s)" % (pkg.package_name, pkg.has_unreplaced_hook)
        for pkg in offenders
    ]
    return (
        ("%s depends on pub package(s) that build native code with a hook " +
         "rules_dart cannot run:\n%s\n\n" +
         "Their `@Native` bindings will not resolve at runtime. Either:\n" +
         "  - name a `dart_code_asset` in this target's `code_assets`, or\n" +
         "  - list the package in `pub.from_lock(ignore_hooks = [...])` if " +
         "its native code is genuinely unused here.") %
        (label, "\n".join(lines))
    )

def _asset_identity(asset):
    """A configuration-independent identity for a code asset.

    Compares the *producing target*, not the `File`: the same
    `cc_shared_library` analysed in two configurations yields two different
    `File`s, which is a diamond rather than a conflict.
    """
    owner = str(asset.dynamic_library.owner) if asset.dynamic_library != None else ""
    return (asset.link_mode, asset.system_uri, owner)

def resolve_code_assets(label, transitive_assets, explicit_assets):
    """Unions transitively-propagated code assets with explicitly named ones.

    An asset id may legitimately arrive many times — through a diamond, or
    because the user named explicitly what a dependency already supplies. Those
    collapse. Two *different* assets claiming one id do not: the Dart VM
    resolves an id to exactly one library, so silently keeping either one would
    pick a native library by graph-traversal order.

    Args:
      label: The consuming target's label, for error messages.
      transitive_assets: `DartCodeAssetInfo` reached through `deps`.
      explicit_assets: `DartCodeAssetInfo` named in the `code_assets` attr.

    Returns:
      List of `DartCodeAssetInfo`, one per asset id, in a stable order.
    """
    by_id = {}
    order = []
    for asset in list(transitive_assets) + list(explicit_assets):
        previous = by_id.get(asset.asset_id)
        if previous == None:
            by_id[asset.asset_id] = asset
            order.append(asset.asset_id)
        elif _asset_identity(previous) != _asset_identity(asset):
            fail(("%s: code asset id `%s` is claimed twice with different " +
                  "definitions: %s and %s. The Dart VM resolves an asset id to " +
                  "exactly one library, so drop one of the declarations.") %
                 (label, asset.asset_id, _asset_identity(previous), _asset_identity(asset)))
    return [by_id[asset_id] for asset_id in order]

def code_asset_entries(label, assets, output_dir):
    """Builds manifest entries and the runfiles library list for code assets.

    Args:
      label: The consuming target's label, for error messages.
      assets: List of `DartCodeAssetInfo`.
      output_dir: Directory the manifest's `relative` paths resolve against
        (the dill's `dirname`).

    Returns:
      `(entries, libraries)` — entries for `generate_native_assets_yaml`, and
      the `File`s that must be staged in runfiles.
    """
    entries = []
    libraries = []
    for info in assets:
        relative_lib_path = ""
        if info.dynamic_library != None:
            relative_lib_path = relative_path(output_dir, info.dynamic_library.path)
            libraries.append(info.dynamic_library)
        entries.append((
            info.asset_id,
            native_assets_path_list(label, info.link_mode, relative_lib_path, info.system_uri),
        ))
    return entries, libraries

def generate_native_assets_yaml(abi, asset_entries):
    """Generates the `native_assets.yaml` content for `gen_kernel --native-assets`.

    Emits the documented format (JSON, which is valid YAML); the VM reads it
    as `vm:ffi:native-assets` kernel metadata.

    Args:
      abi: The `<os>_<arch>` ABI key (see `target_dart_abi`).
      asset_entries: List of `(asset_id, path_list)` tuples, where `path_list`
        comes from `native_assets_path_list`.

    Returns:
      String content of the native_assets.yaml file.
    """
    assets = ", ".join([
        '"{id}": [{path}]'.format(
            id = asset_id,
            path = ", ".join(['"%s"' % part for part in path_list]),
        )
        for (asset_id, path_list) in asset_entries
    ])
    return '{{"format-version": [1, 0, 0], "native-assets": {{"{abi}": {{{assets}}}}}}}\n'.format(
        abi = abi,
        assets = assets,
    )

def gen_kernel_native_assets_action(
        ctx,
        dart_sdk_info,
        main,
        transitive_srcs,
        package_config,
        native_assets_yaml,
        output_dill,
        main_path = None,
        defines = []):
    """Runs `gen_kernel --native-assets=<yaml>` to produce a kernel `.dill`.

    Invokes `dartaotruntime gen_kernel_aot.dart.snapshot --platform <dill>
    --packages <pc> --native-assets <yaml> -o <output> <main>`, embedding the
    code-asset mapping as `vm:ffi:native-assets` metadata. The `.so` files are
    NOT inputs — gen_kernel only embeds the yaml text; the libraries are a
    runtime (runfiles) dependency.

    Args:
      ctx: The rule context.
      dart_sdk_info: The `DartSdkInfo` from the toolchain.
      main: The main `.dart` File.
      transitive_srcs: Depset of transitive source Files.
      package_config: The build-time `package_config.json` File (or None).
      native_assets_yaml: The generated native_assets.yaml File.
      output_dill: The output `.dill` File to produce.
      main_path: Optional path string to compile instead of `main.path` (e.g. a
        path inside an assembled `main` directory).
      defines: Environment declarations; each entry becomes a `-D` flag. This
        action runs the front end, so it is the only stage where they can still
        reach constant evaluation — `dart compile` on the resulting `.dill`
        would accept them and silently do nothing.
    """
    tools = find_sdk_kernel_tools(dart_sdk_info)

    args = ctx.actions.args()
    args.add(tools.gen_kernel_snapshot)
    args.add("--platform", tools.platform_dill)
    if package_config != None:
        args.add("--packages", package_config)
    args.add("--native-assets", native_assets_yaml)
    for d in defines:
        args.add("-D" + d)
    args.add("-o", output_dill)
    args.add(main_path if main_path != None else main)

    direct = [main, native_assets_yaml]
    if package_config != None:
        direct.append(package_config)
    transitive = [dart_sdk_info.tool_files]
    if transitive_srcs != None:
        transitive.append(transitive_srcs)

    env = writable_home_env(dart_sdk_info.dart, output_dill)

    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [args],
        inputs = depset(direct = direct, transitive = transitive),
        outputs = [output_dill],
        mnemonic = "DartGenKernelNativeAssets",
        progress_message = "Compiling Dart kernel with native assets %s" % ctx.label,
        env = env,
    )

def asset_path_for(file, lib_root):
    """Computes the in-package asset path for a File.

    Strips `lib_root` (plus the trailing `/`) from the short_path. When
    `lib_root` is empty the short_path is returned unchanged — that's the
    root-package case and the file's short_path IS its asset path.

    Generated files need one extra step first: `declare_file` paths are
    relative to the *producing rule's* Bazel package, so when a codegen
    target lives in a different Bazel package than the Dart package root,
    the generated short_path is `owner.package + "/" + declared_path`
    where `declared_path` embeds the source's short_path (`dart_codegen`
    declares outputs source-relative). Stripping `owner.package` and then
    `lib_root` recovers the in-package asset path. When the declared path
    does not start with `lib_root` (the codegen target's package is at or
    below the Dart package root with a same-package src), the generated
    short_path mirrors a source file's and the plain `lib_root` strip
    below stays correct.

    Fails loudly when neither derivation matches. Previously this
    silently returned the unmatched short_path, which produced
    `--input-asset` / `--dep` values that couldn't be resolved to any
    `package:` URI — the builder would then produce no output or emit an
    unhelpful `AssetNotFoundException`.

    Args:
      file: The File to compute the asset path for.
      lib_root: The Dart package's short_path prefix (empty for the root
        workspace; e.g. `external/pub_deps++pub+foo` for external pub
        packages).

    Returns:
      The asset path string (relative to the Dart package root).
    """
    rel = file.short_path
    if not lib_root:
        return rel
    if not file.is_source and file.owner != None:
        pkg_prefix = file.owner.package + "/" if file.owner.package else ""
        if pkg_prefix and rel.startswith(pkg_prefix):
            declared = rel[len(pkg_prefix):]
            if declared.startswith(lib_root + "/"):
                return declared[len(lib_root) + 1:]
    if rel.startswith(lib_root + "/"):
        return rel[len(lib_root) + 1:]
    fail(
        ("asset_path_for: file %r (short_path %r) is not under " +
         "lib_root %r. Every codegen input / asset_dep must live inside " +
         "the Dart package's lib_root — check that the owning " +
         "`dart_library` target for this file has the correct " +
         "`package_name`, or pass the file through `deps` instead. For " +
         "generated files, declare the producing codegen target in a " +
         "BUILD file at (or below) the Dart package root so its declared " +
         "output path resolves inside the package.") %
        (file.path, rel, lib_root),
    )

def dart_lib_root_for_package(deps, package_name):
    """Looks up the Dart package's lib_root from the transitive DartInfo set.

    Scans every dep in `deps`; the first `DartPackageInfo` whose
    `package_name` matches wins.

    The rule layer uses this to compute asset paths that survive the
    codegen rule living at a deeper Bazel-package path than the Dart
    package root (e.g. `//myapp/lib:codegen` where the Dart package is
    `//myapp`).

    Args:
      deps: List of targets carrying `DartInfo`.
      package_name: The Dart package name to look up.

    Returns:
      The lib_root string (possibly `""` for the root workspace package),
      or `None` when no matching package is found.
    """
    merged = depset(transitive = [dep[DartInfo].transitive_packages for dep in deps])
    for pkg in merged.to_list():
        if pkg.package_name == package_name:
            return pkg.lib_root
    return None

def same_package_library_dep_files(deps, package_name, exclude_paths = None):
    """Returns same-package sibling files from `deps` plus the package's lib_root.

    Files at `<lib_root>/lib/...` in any transitive package whose name
    matches `package_name` are returned. Filenames whose exec path is in
    `exclude_paths` (e.g. the action's own `src` file) are skipped so the
    input isn't staged twice.

    Args:
      deps: List of targets carrying `DartInfo`.
      package_name: The Dart package name to filter on.
      exclude_paths: Optional list of exec path strings to skip.

    Returns:
      `(files, lib_root)` — the matching sibling Files and the package's
      lib_root. Returns `([], None)` when no matching package is found.
    """
    if exclude_paths == None:
        exclude_paths = []
    lib_root = dart_lib_root_for_package(deps, package_name)
    if lib_root == None:
        return [], None
    prefix = (lib_root + "/lib/") if lib_root else "lib/"
    excluded = {p: True for p in exclude_paths}
    seen = {}
    out = []
    for src in collect_transitive_srcs(deps).to_list():
        if src.path in excluded:
            continue
        if src.short_path in seen:
            continue
        if not src.short_path.startswith(prefix):
            continue
        seen[src.short_path] = True
        out.append(src)
    return out, lib_root

def add_shim_contract_args(
        args,
        ctx,
        synth_pc,
        sdk_dart,
        auto_stage_srcs = [],
        asset_deps = [],
        lib_root = ""):
    """Appends the typed shim-contract flags to `args`.

    Covers `--package`, `--root-language-version`, `--dep` (repeatable —
    `<exec_path>|<asset_path>` form — one per entry in `auto_stage_srcs`
    and `asset_deps`), `--part`, `--config`, `--package-config`,
    `--sdk-path`. Callers add `--input`, `--output`, and `--input-asset`
    themselves (those are specific to the calling impl's per-src /
    per-output loop).

    Args:
      args: The `ctx.actions.args()` object to append flags to.
      ctx: The rule context (reads `package_name`, `config`, etc.).
      synth_pc: The synthesised `package_config.json` File from
        `synth_package_config`, or `None` for targets without
        `library_deps`.
      sdk_dart: The `dart` executable File (from the caller's resolved
        toolchain) used to compute `--sdk-path`. Passed in so this helper
        stays agnostic of which toolchain type the caller resolves.
      auto_stage_srcs: List of Files to emit as `--dep` with
        automatically-computed asset paths. The rule layer calls
        `same_package_library_dep_files` to compute this — users do not
        hand-list sibling files.
      asset_deps: List of Files from the rule's `asset_deps` attr (non-Dart
        files the Builder's Resolver must see via `findAssets` /
        `readAsString`). De-duplicated against `auto_stage_srcs` by exec
        path.
      lib_root: The Dart package's lib_root (used to compute asset paths
        for `auto_stage_srcs` / `asset_deps`).

    Returns:
      A list of extra action-input Files that callers must include in
      their `ctx.actions.run(inputs=...)`.
    """
    if not ctx.attr.package_name:
        fail("%s: `package_name` is required." % ctx.label)

    extra_inputs = []
    args.add("--package", ctx.attr.package_name)

    # When `language_version` is empty the rule defers to a built-in default
    # so users / Gazelle don't have to specify the SDK's `<major>.<minor>` on
    # every macro invocation. Override only when pinning to a specific value.
    args.add("--root-language-version", ctx.attr.language_version or "3.0")
    seen = {}
    for src in auto_stage_srcs:
        if src.path in seen:
            continue
        seen[src.path] = True
        asset = asset_path_for(src, lib_root)
        args.add("--dep", "{}|{}".format(src.path, asset))
        extra_inputs.append(src)
    for src in asset_deps:
        if src.path in seen:
            continue
        seen[src.path] = True
        asset = asset_path_for(src, lib_root)
        args.add("--dep", "{}|{}".format(src.path, asset))
        extra_inputs.append(src)
    for part in ctx.files.parts:
        args.add("--part", part.path)
        extra_inputs.append(part)
    if ctx.attr.config:
        args.add("--config", ctx.attr.config)
    if ctx.file.package_config:
        args.add("--package-config", ctx.file.package_config.path)
        extra_inputs.append(ctx.file.package_config)
    elif synth_pc != None:
        args.add("--package-config", synth_pc.path)
        extra_inputs.append(synth_pc)
    args.add("--sdk-path", sdk_path_from_dart(sdk_dart))
    return extra_inputs
