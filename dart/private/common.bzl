"""Shared utilities for Dart rules."""

load("//dart:providers.bzl", "CODE_ASSET_LINK_MODES", "DartCodeAssetInfo", "DartInfo", "DartPackageMetadataInfo")
load("//dart/private:dart_info.bzl", "derived_package_info", "package_lib_prefix")
load("//dart/private:exec_groups.bzl", "PORTABLE", "portable_sdk")
load("//dart/private:resources.bzl", "kernel_resources")
load("//dart/private:source_set.bzl", "needs_source_assembly", "package_for_index", "package_index")

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

def package_link_hook(pkg):
    """A `DartPackageInfo`'s `hook/link.dart`, tolerating older producers.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      The hook File, or `None` when the package has none or the record
      predates the field.
    """
    return getattr(pkg, "link_hook", None)

def package_license_file(pkg):
    """A `DartPackageInfo`'s license text, tolerating older producers.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      The license File, or `None` when the package has none or the record
      predates the field.
    """
    return getattr(pkg, "license_file", None)

def _license_key(pkg):
    """What two records' license files must share to name the same license.

    The path within the package, not the File: two pub hubs supplying one
    package each fetch its archive, so their records name different Files
    (`../hub_a__ffi/LICENSE`, `../hub_b__ffi/LICENSE`) for the same text. A
    file outside the package root is compared by its own path.
    """
    f = package_license_file(pkg)
    if f == None:
        return ""
    prefix = pkg.lib_root + "/" if pkg.lib_root else ""
    if prefix and f.short_path.startswith(prefix):
        return f.short_path[len(prefix):]
    return f.short_path

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

def own_packages(info):
    """Returns the `DartPackageInfo` records of the packages a `DartInfo` itself contributes.

    Usually one; none for a target built by `dart_info_no_package()`; several
    for the library pub generates over packages that depend on each other.

    Args:
      info: A `DartInfo`.

    Returns:
      A list of `DartPackageInfo`. Empty for a provider predating the field.
    """
    return list(getattr(info, "packages", ()))

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

_VERSION_REMEDY = """
Each package listed just above was resolved to different versions by two
package sources. Typically two pub hubs — rules_flutter's `flutter.pub()` and
rules_dart's `pub.from_lock()` each generating a spoke for the same package —
whose lock files have drifted apart. Only one record per package can win, and
dependency order would decide which, so the build would compile against
whichever came first regardless of what the other's lock pins.

Reconcile the lock files feeding the two hubs so both pin one version of each:
re-resolve the lagging lock with the toolchain that builds it, from the root of
the workspace that holds it. For a lock `pub.from_lock()` reads:

  bazel run @rules_dart//dart/pub -- upgrade --directory=<the lock's directory> <package>

Every package that disagrees is listed, so one reconciliation settles all of
them.

rules_dart does not support multiple versions of a package.
"""

_LICENSE_FILE_REMEDY = """
Each package listed just above has records naming different license files, so
which license text the package is reported with would be decided by dependency
order. Name the same file on every target contributing to the package
(`dart_library.license_file`, or `license_file` of `dart_package_info()` or
`dart_package_member_info()`), or name it on one and leave the others unset.
"""

_LANGUAGE_VERSION_REMEDY = """
Each package listed just above has records stating different
`language_version`s, so the Dart semantics its sources compile under would be
decided by dependency order. Set `language_version` consistently on every
`dart_library` contributing to the package — Gazelle derives it from the
nearest `pubspec.yaml`'s `environment.sdk` constraint and writes the same value
on each.
"""

# The language version a code generator's root package is assumed to have when
# nothing states one. Deliberately old: a generator running under a *lower*
# language version than the sources it reads is the safe direction, since the
# analyzer then refuses syntax the real package would accept rather than
# accepting syntax it would not. Prefer stating the real value — `dart_package_metadata`
# exists so it only has to be stated once — and note that
# `codegen_identity_error` reports this default when it contradicts a library
# that does state one.
DEFAULT_ROOT_LANGUAGE_VERSION = "3.0"

# The attribute every rule that builds part of a Dart package gains, pointing at
# the one `dart_package_metadata` that declares the package's name and language version.
PACKAGE_IDENTITY_ATTRS = {
    "package": attr.label(
        providers = [DartPackageMetadataInfo],
        doc = "A `dart_package_metadata` declaring this Dart package's `package_name` and `language_version`. Mutually exclusive with the inline `package_name` / `language_version` attributes: set `package` to state those facts once for every rule building this package, or set them inline, but never both. Referencing a target is what lets rules in *different* BUILD files share one declaration, which a macro cannot do.",
    ),
}

def resolve_package_identity(ctx):
    """Resolves a rule's Dart package identity from `package` or inline attrs.

    Two ways to state one thing would be two ways for it to be wrong, so this
    refuses the overlap outright rather than defining a precedence: a rule that
    sets `package` and an inline attribute fails, whether or not the two agree.
    Agreement today is not agreement after the next edit, and a silently ignored
    attribute is the failure this whole mechanism exists to remove.

    Tolerant about which attributes the calling rule actually declares: a rule
    with a `language_version` and no `package_name` needs no change here.

    Args:
      ctx: The rule context. Must declare `package`; may declare
        `package_name` and/or `language_version`.

    Returns:
      `struct(package_name, language_version)`, either of which may be "".
    """
    inline_name = getattr(ctx.attr, "package_name", "")
    inline_language_version = getattr(ctx.attr, "language_version", "")
    declaration = getattr(ctx.attr, "package", None)

    if declaration == None:
        return struct(
            package_name = inline_name,
            language_version = inline_language_version,
        )

    also_set = []
    if inline_name:
        also_set.append("package_name")
    if inline_language_version:
        also_set.append("language_version")
    if also_set:
        fail(("%s: sets `package` and also %s. `package = \"%s\"` already " +
              "states %s for this package; drop the inline %s, or drop " +
              "`package` and state everything inline.") % (
            ctx.label,
            " and ".join(["`%s`" % a for a in also_set]),
            declaration.label,
            "them" if len(also_set) > 1 else "it",
            "attributes" if len(also_set) > 1 else "attribute",
        ))

    declared = declaration[DartPackageMetadataInfo]
    return struct(
        package_name = declared.package_name,
        language_version = declared.language_version,
    )

def codegen_identity_error(label, srcs, identity):
    """Reports a generated source whose package identity contradicts its library.

    `dart_codegen` and its consuming `dart_library` each state the package the
    generated file belongs to, and `dart_codegen`'s own documentation has always
    required them to match — with nothing checking that they do. They cannot be
    made to agree by construction either: the library depends on the codegen's
    output, so no provider reaches from the codegen to the library, and the two
    are routinely written in different BUILD files. `srcs` is where they meet.

    The language version compared here is the generator's *effective* one, so a
    `dart_codegen` that states none — and therefore ran under
    `DEFAULT_ROOT_LANGUAGE_VERSION` — is reported against a library that states
    3.11, instead of the mismatch surfacing later as a generated file the
    analyzer rejects. A library that states none of its own asks for nothing and
    is not second-guessed: `e2e/fix/clean` is that shape, both sides silent, and
    it is not this function's business to invent an opinion for it.

    Args:
      label: The consuming rule's label, for the error message.
      srcs: The consuming rule's `srcs` targets (`ctx.attr.srcs`).
      identity: The consuming rule's own `resolve_package_identity` result.

    Returns:
      An error message string, or `None` when nothing contradicts.
    """
    for src in srcs:
        if DartPackageMetadataInfo not in src:
            continue
        generated = src[DartPackageMetadataInfo]
        if generated.package_name != identity.package_name:
            return (
                ("%s: generates sources for package \"%s\", but %s collects " +
                 "them into package \"%s\". A generated file is part of the " +
                 "package whose sources it was generated from — the two must " +
                 "name the same one. Point both at a single `dart_package_metadata`, " +
                 "or correct whichever `package_name` is wrong.") % (
                    src.label,
                    generated.package_name,
                    label,
                    identity.package_name,
                )
            )
        if not identity.language_version:
            continue
        if generated.language_version != identity.language_version:
            return (
                ("%s: ran its generator under Dart language version %s, but " +
                 "%s compiles package \"%s\" as %s.%s\n\nThe generator reads " +
                 "the package's sources to produce the file, so a generator " +
                 "held to different semantics than the package can reject " +
                 "syntax the package legitimately uses, or emit syntax the " +
                 "package cannot compile. Point both at a single " +
                 "`dart_package_metadata`, or set the same `language_version` on " +
                 "each.") % (
                    src.label,
                    generated.language_version,
                    label,
                    identity.package_name,
                    identity.language_version,
                    (
                        " %s states no `language_version`, so it fell back to the built-in default." % src.label
                    ) if generated.language_version == DEFAULT_ROOT_LANGUAGE_VERSION else "",
                )
            )
    return None

def package_agreement_error(merged):
    """Reports every duplicate record that states facts its twin contradicts.

    Two records for one `package_name` are normal — see `merge_package_records`
    for why — but they are supposed to describe the *same* package. When they
    disagree, `merge_package_records` keeps the first and discards the second,
    which silently substitutes one version's entire source tree for the other's.
    A skewed pair of lock files reproduces exactly that: the build succeeds, no
    diagnostic is emitted, and a package compiles against sources its own lock
    does not pin.

    Only two *known* values can disagree. A record whose producer does not emit
    the field carries "" — every `DartPackageInfo` built by a rule set that
    predates it, and every hand-written `dart_library`, which has no version to
    state. Treating "" as a disagreement would fail every dual-hub build
    including the agreeing ones; treating it as "knows less" is what lets the
    field be adopted one producer at a time.

    The license file is compared by its path within the package rather than as
    a File, for the reason `_license_key` gives.

    Every disagreement is reported at once, across every field, because the
    cause is almost always one skew producing many of them: a pair of lock
    files that drifted apart disagrees about every package whose version moved
    between them. Naming only the first turns one reconciliation into a round
    of fix-one, re-analyse, see-the-next per package, and `--keep_going` buys
    nothing since every failing target reports that same first name. The full
    list costs nothing to produce — it is already accumulated before the first
    is found.

    Pure, and separate from `merge_package_records`, for the same reason
    `check_code_asset_ownership` is separate from `dart_info`: the caller owns
    the `fail`, so the rule can be tested by calling it.

    Args:
      merged: List of DartPackageInfo, with duplicates, in dependency order.

    Returns:
      An error message string naming every disagreement, or `None` when every
      duplicate agrees.
    """
    blocks = []
    for read, label, remedy in (
        (lambda pkg: getattr(pkg, "version", ""), "versions", _VERSION_REMEDY),
        (lambda pkg: getattr(pkg, "language_version", ""), "language versions", _LANGUAGE_VERSION_REMEDY),
        (_license_key, "license files", _LICENSE_FILE_REMEDY),
    ):
        # value -> lib_root of the first record stating it, per package name.
        stated = {}
        for pkg in merged:
            value = read(pkg)
            if not value:
                continue
            seen = stated.setdefault(pkg.package_name, {})
            if value not in seen:
                seen[value] = pkg.lib_root

        reported = []
        for package_name in sorted(stated.keys()):
            seen = stated[package_name]
            if len(seen) < 2:
                continue
            reported.append(
                "Package \"%s\" is supplied more than once with different %s:\n" % (package_name, label) +
                "".join([
                    "  - %s (%s)\n" % (value, seen[value])
                    for value in sorted(seen.keys())
                ]),
            )

        # One remedy per field, after that field's packages: the fix is the
        # same for all of them, and repeating the paragraph per package is what
        # makes a wide report unreadable.
        if reported:
            blocks.append("".join(reported) + remedy)

    if not blocks:
        return None
    return "\n".join(blocks)

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

    First-record-wins is only safe once the records are known to agree, so this
    calls `package_agreement_error` first and fails when two of them state
    different `version`s, `language_version`s or `license_file`s. `has_unreplaced_hook` stays
    order-decided and deliberately unchecked: unlike the other two it is derived
    at repo generation rather than stated by a developer, and two hubs can
    legitimately disagree — one curating `code_assets` so the hook counts as
    replaced while the other still flags it.

    Split out from `collect_packages` because the dedup and union rules are a
    pure function of the record list, which makes them directly testable
    without synthesising `DartInfo`-bearing targets. The agreement check keeps
    that property by living in its own function and returning its message.

    Args:
        merged: List of DartPackageInfo, with duplicates, in dependency order.

    Returns:
        List of unique DartPackageInfo providers in dependency order.
    """
    err = package_agreement_error(merged)
    if err != None:
        fail(err)

    packages = []
    index_by_name = {}
    for pkg in merged:
        index = index_by_name.get(pkg.package_name)
        if index == None:
            index_by_name[pkg.package_name] = len(packages)
            packages.append(pkg)
        else:
            kept = packages[index]
            adopt_hook = package_link_hook(pkg) != None and package_link_hook(kept) == None
            adopt_license = package_license_file(pkg) != None and package_license_file(kept) == None
            if not package_code_assets(pkg) and not adopt_hook and not adopt_license:
                continue

            # Only the assets, a missing link hook and a missing license merge
            # (the license only once the agreement check has passed, so it can
            # differ only by being absent); every other field
            # stays the kept record's. The link hook is adopted for the same
            # reason the assets are: a package split across targets may carry
            # its `hook/link.dart` on any one of them, and dropping it would
            # silently skip the hook. `has_unreplaced_hook` is not merged, so
            # two hubs supplying one package can disagree about whether the
            # hook was replaced and dependency order decides which answer
            # survives. Recorded rather than quietly changed: picking the other
            # one is a semantic call about what a replaced hook means for a
            # package reached twice.
            packages[index] = derived_package_info(
                kept,
                code_assets = package_code_assets(kept) + package_code_assets(pkg),
                link_hook = package_link_hook(pkg) if adopt_hook else None,
                license_file = package_license_file(pkg) if adopt_license else None,
            )
    return packages

def launcher_executable(ctx, tool):
    """Symlinks a pre-compiled launcher as a rule's executable, `<name>[.exe]`.

    Keeps the launcher's `.exe` extension, which Windows needs to run it. A
    launcher that reads a configuration finds it beside this executable, at
    `<name>.launcher.json` (`launcher_config.dart`). The launcher must be built
    for the host the executable runs on: with `cfg = "target"` where the rule
    is itself built for that host, as `dart_test` and `dart_binary` are, or with
    `config.exec("test")` where a test must run on the test execution group's
    host whatever the target, as the analysis tests do.

    Args:
      ctx: The rule context.
      tool: The launcher target, built for the host the test runs on.

    Returns:
      `struct(executable, runfiles)` — the declared symlink and the launcher's
      own runfiles, for the caller to merge with its own.
    """
    binary = tool[DefaultInfo].files_to_run.executable
    ext = ".exe" if binary.extension == "exe" else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(output = executable, target_file = binary, is_executable = True)
    return struct(executable = executable, runfiles = tool[DefaultInfo].default_runfiles)

# The environment of an action that runs the SDK's `dart`, which suppresses its
# analytics: dartdev otherwise records them under the home directory. No action
# needs a home of its own; one that compiles for a cross target adds the home
# its `cross_tools` names. A runnable target that starts `dart` for the user
# (`@rules_dart//dart`, `dart_format`) sets it too: the home is then the
# user's own.
SDK_ENV = {"DASH__SUPPRESS_ANALYTICS": "true"}

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

    Ownership is `package_for`'s and only `package_for`'s: a file resolves a
    package's root only if it is one the package could actually export — under
    `<lib_root>/lib/`, or the `lib_root` directory itself. Matching anything
    else under `lib_root` was the bug: a `dart_test` sitting in the same Bazel
    package as the library it tests (`packages/foo/BUILD.bazel` declaring both
    `dart_library(foo)` and its test, which is the ordinary pub layout) makes
    the rule declare its dependencies' assembled `.pkgsrcs` directories at
    `packages/foo/<test>.<dep>.pkgsrcs`. That path starts with `packages/foo/`,
    so `foo` claimed it and resolved its own root to
    `bazel-out/.../bin/packages/foo` — a directory with no `lib/` in it — and
    every `package:foo/…` import failed to read.

    Having the match live in one function also keeps this in step with
    `generate_dev_package_config`, which groups the same files by `package_for`
    and then reads the roots computed here; the two disagreeing meant a
    package's files and its root could come from different packages.

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

    by_name = {pkg.package_name: pkg for pkg in packages}
    roots = {}
    index = package_index(packages)
    for src in all_srcs:
        name = package_for_index(src.short_path, index)
        if name == None or name in roots:
            continue

        roots[name] = package_root_of(src, by_name[name].lib_root)
    return roots

def package_root_of(src, lib_root):
    """Returns the exec-root-relative root of the package `src` belongs to.

    Args:
        src: A File the package owns (see `package_for`).
        lib_root: The owning package's `lib_root`.

    Returns:
        The exec path of the package root directory.
    """

    # The package-relative tail, stripped off the exec path to leave the
    # root. Empty when the file *is* the package root (an assembled
    # directory); otherwise "/lib/…", or "lib/…" for the root package,
    # whose empty `lib_root` leaves a trailing slash to trim.
    suffix = src.short_path[len(lib_root):]
    exec_root = src.path[:len(src.path) - len(suffix)]
    if exec_root.endswith("/"):
        exec_root = exec_root[:-1]
    return exec_root

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
    index = package_index(packages)
    for f in all_srcs:
        name = package_for_index(f.short_path, index)
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
            lib_prefix = package_lib_prefix(pkg.lib_root)
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
      `(package_config_file, package_files_depset)`, or `(None, None)`
      when `library_deps` is empty. The depset holds every file of every
      package the config names, sources and `resources` alike: a generator
      may read any of them through the config, so the caller adds both to
      the action's `inputs` (the depset flattens lazily at execution time).
    """
    if not library_deps:
        return None, None
    packages = collect_packages(library_deps)
    transitive_srcs = collect_transitive_srcs(library_deps)
    package_files = depset(
        transitive = [transitive_srcs, collect_transitive_resources(library_deps)],
    )
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
    return package_config, package_files

# --- Native code-asset (frontend_server --native-assets) helpers ---
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
    """Locates the front-end toolchain files within the SDK tree.

    Returns a struct with the `dartaotruntime` executable, the
    `frontend_server_aot.dart.snapshot`, and the two VM platform dills `dart
    compile` chooses between (`vm_platform_product.dill` for a product
    runtime, `vm_platform.dill` for the JIT VM), found by exact path under the
    SDK root within the SDK's `kernel` set.

    Args:
      dart_sdk_info: The `DartSdkInfo` from the toolchain.

    Returns:
      `struct(dartaotruntime, frontend_server_snapshot, platform_dill,
      platform_product_dill)` of Files.
    """
    sdk_root = sdk_path_from_dart(dart_sdk_info.dart)
    wanted = {
        "dartaotruntime": [
            sdk_root + "/bin/dartaotruntime",
            sdk_root + "/bin/dartaotruntime.exe",
        ],
        "frontend_server_snapshot": [sdk_root + "/bin/snapshots/frontend_server_aot.dart.snapshot"],
        "platform_dill": [sdk_root + "/lib/_internal/vm_platform.dill"],
        "platform_product_dill": [sdk_root + "/lib/_internal/vm_platform_product.dill"],
    }
    found = {}

    # Analysis-time path probe for 4 files; a legitimate one-time flatten.
    for f in dart_sdk_info.files.kernel.to_list():
        for key, paths in wanted.items():
            if f.path in paths:
                found[key] = f
    for key in wanted:
        if key not in found:
            fail(("find_sdk_kernel_tools: could not locate %s under SDK root " +
                  "%r (Dart %s). The SDK layout may have changed across " +
                  "versions; every VM compile runs the AOT frontend_server " +
                  "snapshot.") %
                 (key, sdk_root, dart_sdk_info.version))
    return struct(
        dartaotruntime = found["dartaotruntime"],
        frontend_server_snapshot = found["frontend_server_snapshot"],
        platform_dill = found["platform_dill"],
        platform_product_dill = found["platform_product_dill"],
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

def code_asset_identity(asset):
    """The identity two code assets share exactly when they are one library.

    Compares the library `File`, so one target built in two configurations is
    two libraries: a transition that reaches it changed a setting it may be
    built with (`-c`, a platform, a copt), and nothing at analysis time can
    tell whether the bytes still agree.

    Args:
      asset: A `DartCodeAssetInfo`.

    Returns:
      A tuple that two assets share exactly when they define one library.
    """
    library = asset.dynamic_library.path if asset.dynamic_library != None else ""
    return (asset.link_mode, asset.system_uri, library)

def resolve_code_assets(label, transitive_assets, explicit_assets):
    """Unions transitively-propagated code assets with explicitly named ones.

    An asset id may legitimately arrive many times, through a diamond, and
    those collapse. Two *different* assets claiming one id through `deps` do
    not: the Dart VM resolves an id to exactly one library, so silently keeping
    either one would pick a native library by graph-traversal order. An asset
    named in the `code_assets` attr is a choice rather than an accident of the
    graph, so it replaces whatever `deps` supply under its id: how a test loads
    a differently built library under the id its package declares, and how a
    target settles two `deps` that claim one id with different libraries.

    Args:
      label: The consuming target's label, for error messages.
      transitive_assets: `DartCodeAssetInfo` reached through `deps`.
      explicit_assets: `DartCodeAssetInfo` named in the `code_assets` attr.

    Returns:
      List of `DartCodeAssetInfo`, one per asset id, in a stable order.
    """
    explicit = _unique_code_assets(label, explicit_assets)
    named = {asset.asset_id: True for asset in explicit}
    return _unique_code_assets(label, [
        asset
        for asset in transitive_assets
        if asset.asset_id not in named
    ]) + explicit

def _unique_code_assets(label, assets):
    """`assets` with duplicates collapsed, failing on two definitions of one id."""
    by_id = {}
    order = []
    for asset in assets:
        previous = by_id.get(asset.asset_id)
        if previous == None:
            by_id[asset.asset_id] = asset
            order.append(asset.asset_id)
        elif code_asset_identity(previous) != code_asset_identity(asset):
            same_target = (
                previous.dynamic_library != None and asset.dynamic_library != None and
                previous.dynamic_library.owner == asset.dynamic_library.owner
            )
            fail(("%s: code asset id `%s` is claimed twice with different " +
                  "definitions: %s and %s. The Dart VM resolves an asset id to " +
                  "exactly one library, so %s, or name the one to use in this " +
                  "target's `code_assets`.") % (
                label,
                asset.asset_id,
                code_asset_identity(previous),
                code_asset_identity(asset),
                ("this is %s built in two configurations: a transition between " +
                 "here and one of them changes a setting it is built with; reset " +
                 "that setting before the library") % asset.dynamic_library.owner if same_target else "drop one of the declarations",
            ))
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
            if info.dynamic_library not in libraries:
                libraries.append(info.dynamic_library)
        entries.append((
            info.asset_id,
            native_assets_path_list(label, info.link_mode, relative_lib_path, info.system_uri),
        ))
    return entries, libraries

def stage_code_assets(ctx, assets, directory):
    """`assets` with each library linked into the target's own package, once.

    A `relative` manifest path from the target's output to a file the target
    declares itself holds wherever the two travel together: bazel-bin, any
    runfiles tree, or a copy of both.

    Several ids may name one library, as when one shared library serves
    several packages. They share one link, so the OS loader opens one image
    for all of them; two links would load two copies of the library.

    Args:
      ctx: The target's rule context.
      assets: List of `DartCodeAssetInfo`.
      directory: Function from a library's index among the distinct libraries
        to the directory, relative to the target's package, to link it into.

    Returns:
      List of `DartCodeAssetInfo` parallel to `assets`, each naming its linked
      library, or the asset itself when it has no library.
    """
    links = {}
    staged = []
    for asset in assets:
        library = asset.dynamic_library
        if library == None:
            staged.append(asset)
            continue
        if library not in links:
            link = ctx.actions.declare_file("%s/%s" % (directory(len(links)), library.basename))
            ctx.actions.symlink(output = link, target_file = library)
            links[library] = link
        staged.append(DartCodeAssetInfo(
            asset_id = asset.asset_id,
            link_mode = asset.link_mode,
            dynamic_library = links[library],
            system_uri = asset.system_uri,
        ))
    return staged

def generate_native_assets_yaml(abi, asset_entries):
    """Generates the `native_assets.yaml` content for `frontend_server --native-assets`.

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

# The execution requirement of an action whose arguments and inputs name no
# configuration's output directory except through its Files, so that under
# `--experimental_output_paths=strip` one result serves every configuration
# that builds the same thing. A path in a string, or in a file's content,
# breaks that: it names one configuration, and inside the sandbox of a mapped
# action it does not exist.
PATH_MAPPING = {"supports-path-mapping": "1"}

# The URI scheme every VM compile reads its sources through, rooted at the exec
# root. See `dart_kernel_action`.
KERNEL_FILESYSTEM_SCHEME = "org-dartlang-root"

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

def _kernel_root(f):
    rel = kernel_root_path(f.short_path)
    if f.path != rel and f.path.endswith("/" + rel):
        return f.path[:-len(rel) - 1]
    return None

def add_kernel_roots(args, flag, files):
    """Adds the kernel filesystem roots `files` are found under, output directories first.

    The exec root, plus the output directory of each generated file; a file's
    root is what is left of its path once its `short_path` is taken off. The
    output directories come first so a generated file wins over a stale copy
    at the same path in the source tree: a sandbox hides the stale one, but a
    persistent worker runs in the exec root, where it is visible.

    The roots are worked out from the Files as the action's arguments are
    written, so they are the paths the action sees when Bazel maps its output
    paths (`--experimental_output_paths=strip`).

    Args:
      args: The `Args` to add them to.
      flag: The flag each root follows.
      files: A list or depset of Files a compile reads from source.
    """
    args.add_all(files, map_each = _kernel_root, before_each = flag, uniquify = True, expand_directories = False)
    args.add(flag, ".")

def _kernel_uri(f):
    return KERNEL_FILESYSTEM_SCHEME + ":///" + f.path

def _sdk_root(platform):
    return platform.dirname + "/"

def dart_kernel_action(
        ctx,
        main,
        transitive_srcs,
        package_config,
        output_dill,
        product,
        defines = [],
        flags = [],
        native_assets_yaml = None,
        track_creation_locations = False,
        kernel_tool = None):
    """Runs the Dart front end (`frontend_server`) to produce a kernel `.dill`.

    Every VM compile goes through here first, and `dart compile` then turns the
    kernel into a snapshot or executable. The front end names each library that
    is not in a package by its URI, and the compiled program keeps those URIs:
    in stack traces, and in the private-name suffixes derived from them, which
    reach every part of the output. `dart compile` given a source path names
    the entrypoint `file:///<absolute path>`, so the bytes depended on where
    the action ran — the sandbox directory, the output base. Here the sources
    are read through `KERNEL_FILESYSTEM_SCHEME`, rooted at the exec root and
    the output directories the sources lie in (`add_kernel_roots`), so the
    entrypoint is `org-dartlang-root:///<path in the workspace>` wherever and
    in whichever configuration it was built, and its relative imports resolve
    within those roots exactly as they do on disk. `package_config` names its
    packages the same way (`kernel_package_config`).

    The other flags are the ones `dart compile` itself passes to the front end
    (`generateKernelHelper` in `pkg/dart2native`): the platform dill and
    `dart.vm.product` that match the runtime the kernel is for, and the
    sanitizer defines, which are false in a released SDK. They are constants the
    front end folds, so they have to be right here; the step after sees only the
    folded result.

    `frontend_server`, not `gen_kernel`, because it keeps a `-D` value whole:
    `gen_kernel` splits every one on commas, so `-DA=x,y` would reach the
    program as `A=x`. It runs as a one-shot compile of the entrypoint named on
    its command line, and prints its protocol (a result line, the diagnostics,
    an error count) rather than a quiet success; a compile with errors exits
    non-zero. Its default is an ordinary non-incremental compile that writes
    only `--output-dill`; `--no-print-incremental-dependencies` leaves out the
    list of files read, which would name absolute paths in the build log. The
    platform dill is named relative to `--sdk-root`.

    Bazel shows the output of every action that succeeds, and the protocol is
    output even when nothing is wrong, so `kernel_tool frontend` runs the
    server and shows only the compiler's own messages. `kernel_tool` is built
    by a `dart_binary`, so the targets that build it (`dart_tool_binary` and
    `dart_bootstrap_binary`, which have no `_kernel_tool` of their own) pass no
    `kernel_tool` and run the server directly; each of those compiles prints
    the protocol once, when it is built.

    A kernel is the same whichever host compiles it, so this runs in
    `PORTABLE`, with that host's SDK.

    Args:
      ctx: The rule context; the rule declares `PORTABLE_EXEC_GROUPS`.
      main: The entrypoint `.dart` File.
      transitive_srcs: Depset of transitive source Files.
      package_config: The `kernel_package_config` File, or None.
      output_dill: The output `.dill` File to produce.
      product: Whether the kernel is for a product runtime: an AOT snapshot or
        executable, or a `dart compile kernel` file. False for the JIT VM that
        builds a `jit-snapshot`.
      defines: Environment declarations; each entry becomes a `-D` flag. This
        action runs the front end, so it is the only stage where they can still
        reach constant evaluation.
      flags: Further front-end flags, e.g. `--enable-experiment=...`; those
        `frontend_server` accepts.
      native_assets_yaml: Optional `native_assets.yaml` File, embedded as the
        `vm:ffi:native-assets` mapping. The libraries it names are a run-time
        (runfiles) dependency, not inputs.
      track_creation_locations: Whether to pass `--track-creation-locations`,
        which the whole program, here, is compiled with or without.
      kernel_tool: The `kernel_tool` executable to run the front end through,
        or None to run it directly (see above).
    """
    dart_sdk_info = portable_sdk(ctx)
    tools = find_sdk_kernel_tools(dart_sdk_info)
    platform = tools.platform_product_dill if product else tools.platform_dill

    args = ctx.actions.args()
    args.add(tools.frontend_server_snapshot)
    args.add_all([platform], before_each = "--sdk-root", map_each = _sdk_root)
    args.add("--platform", platform.basename)
    args.add("-Ddart.vm.product=" + ("true" if product else "false"))
    args.add_all(["-Ddart.vm.asan=false", "-Ddart.vm.msan=false", "-Ddart.vm.tsan=false"])
    args.add("--no-print-incremental-dependencies")
    args.add("--filesystem-scheme", KERNEL_FILESYSTEM_SCHEME)
    add_kernel_roots(args, "--filesystem-root", depset([main], transitive = [transitive_srcs] if transitive_srcs != None else []))
    if package_config != None:
        args.add_all([package_config], before_each = "--packages", map_each = _kernel_uri)
    if native_assets_yaml != None:
        args.add("--native-assets", native_assets_yaml)
    for d in defines:
        args.add("-D" + d)
    if track_creation_locations:
        args.add("--track-creation-locations")
    args.add_all(flags)
    args.add("--output-dill", output_dill)
    args.add(KERNEL_FILESYSTEM_SCHEME + ":///" + kernel_root_path(main.short_path))

    # The front end reads only the files it is named: its snapshot, the
    # runtime and the platform.
    direct = [main, tools.dartaotruntime, tools.frontend_server_snapshot, platform]
    if package_config != None:
        direct.append(package_config)
    if native_assets_yaml != None:
        direct.append(native_assets_yaml)
    transitive = []
    if transitive_srcs != None:
        transitive.append(transitive_srcs)

    if kernel_tool != None:
        executable = kernel_tool
        launch = ctx.actions.args()
        launch.add("frontend")
        launch.add("--runtime", tools.dartaotruntime)
        launch.add("--")
        arguments = [launch, args]
    else:
        executable = tools.dartaotruntime
        arguments = [args]
    ctx.actions.run(
        executable = executable,
        arguments = arguments,
        inputs = depset(direct = direct, transitive = transitive),
        outputs = [output_dill],
        mnemonic = "DartKernel",
        resource_set = kernel_resources,
        exec_group = PORTABLE,
        progress_message = "Compiling Dart kernel %s" % ctx.label,
        env = SDK_ENV,
        execution_requirements = PATH_MAPPING,
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

    Sources and `resources` alike: files at `<lib_root>/lib/...` in any
    transitive package whose name matches `package_name` are returned. Filenames whose exec path is in
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
    prefix = package_lib_prefix(lib_root)
    excluded = {p: True for p in exclude_paths}
    seen = {}
    out = []
    files = depset(
        transitive = [collect_transitive_srcs(deps), collect_transitive_resources(deps)],
    )
    for src in files.to_list():
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
    `<path>|<asset_path>` form — one per entry in `auto_stage_srcs`
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
    identity = resolve_package_identity(ctx)
    if not identity.package_name:
        fail(("%s: no `package_name`. Set it on this rule, or set `package` " +
              "to a `dart_package_metadata` that declares it.") % ctx.label)

    extra_inputs = []
    args.add("--package", identity.package_name)

    # When `language_version` is empty the rule defers to a built-in default
    # so users / Gazelle don't have to specify the SDK's `<major>.<minor>` on
    # every macro invocation. Override only when pinning to a specific value —
    # via `package` for a package built by more than one rule.
    args.add(
        "--root-language-version",
        identity.language_version or DEFAULT_ROOT_LANGUAGE_VERSION,
    )
    seen = {}
    for src in auto_stage_srcs:
        if src.path in seen:
            continue
        seen[src.path] = True
        args.add("--dep", src, format = "%s|" + format_literal(asset_path_for(src, lib_root)))
        extra_inputs.append(src)
    for src in asset_deps:
        if src.path in seen:
            continue
        seen[src.path] = True
        args.add("--dep", src, format = "%s|" + format_literal(asset_path_for(src, lib_root)))
        extra_inputs.append(src)
    for part in ctx.files.parts:
        args.add("--part", part)
        extra_inputs.append(part)
    if ctx.attr.config:
        args.add("--config", ctx.attr.config)
    if ctx.file.package_config:
        args.add("--package-config", ctx.file.package_config)
        extra_inputs.append(ctx.file.package_config)
    elif synth_pc != None:
        args.add("--package-config", synth_pc)
        extra_inputs.append(synth_pc)
    args.add_all([sdk_dart], before_each = "--sdk-path", map_each = sdk_path_from_dart)
    return extra_inputs

def format_literal(text):
    """`text` escaped for an `Args` format string, in which `%` is special."""
    return text.replace("%", "%%")
