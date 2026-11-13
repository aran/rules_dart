"""Shared utilities for Dart rules."""

load("//dart:providers.bzl", "CODE_ASSET_LINK_MODES", "DartCodeAssetInfo", "DartInfo", "DartPackageInfo", "DartPackageMetadataInfo")
load("//dart/ext:registry.bzl", "curated_versions")
load("//dart/private:dart_info.bzl", "derived_package_info", "package_info_from_metadata", "package_lib_prefix")
load("//dart/private:exec_groups.bzl", "PORTABLE", "portable_sdk")
load("//dart/private:package_root.bzl", "derive_package_root")
load("//dart/private:resources.bzl", "kernel_resources")
load("//dart/private:source_set.bzl", "needs_source_assembly", "package_for_index", "package_index")

visibility("//dart/...")

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
    """Code assets declared on a `DartPackageInfo`.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      Tuple of `DartCodeAssetInfo`.
    """
    return pkg.code_assets

def package_data_assets(pkg):
    """Data assets declared on a `DartPackageInfo`.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      Tuple of `struct(package, name, file, id)`.
    """
    return pkg.data_assets

def package_link_hook(pkg):
    """A `DartPackageInfo`'s `hook/link.dart`.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      The hook File, or `None` when the package has none.
    """
    return pkg.link_hook

def package_link_hook_assets(pkg):
    """The ids of the data assets a `DartPackageInfo`'s link hook always emits.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      Tuple of ids, each `package:<package>/<name>`; empty when none.
    """
    return pkg.link_hook_assets

def package_linked_code_assets(pkg):
    """The native code a `DartPackageInfo` links into each program.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      Tuple of `DartLinkedCodeAssetInfo`.
    """
    return pkg.linked_code_assets

def package_license_file(pkg):
    """A `DartPackageInfo`'s license text.

    Args:
      pkg: A `DartPackageInfo`.

    Returns:
      The license File, or `None` when the package has none.
    """
    return pkg.license_file

def _in_package_key(pkg, f):
    """What two records' files must share to name the same file of the package.

    The path within the package, not the File: two pub hubs supplying one
    package each fetch its archive, so their records name different Files
    (`../hub_a__ffi/LICENSE`, `../hub_b__ffi/LICENSE`) for the same text. A
    file outside the package root is compared by its own path.
    """
    if f == None:
        return ""
    prefix = pkg.package_root + "/" if pkg.package_root else ""
    if prefix and f.short_path.startswith(prefix):
        return f.short_path[len(prefix):]
    return f.short_path

def _license_key(pkg):
    return _in_package_key(pkg, package_license_file(pkg))

def _link_hook_key(pkg):
    return _in_package_key(pkg, package_link_hook(pkg))

def _link_hook_assets_key(pkg):
    return ", ".join(package_link_hook_assets(pkg))

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

def program_packages(package, deps):
    """Every package of a program: its own, when it has one, and those its deps reach.

    A program's own package is one of its packages exactly as a dependency's
    is, as upstream's hooks runner plans the root package with the rest: its
    code and data assets ship and its link hook runs. Merged as
    `collect_packages` merges, the program's record first, so a library in
    `deps` of the same package merges into it.

    Args:
      package: The program's own `DartPackageInfo` (`executable_package_record`,
        or the record a rule whose sources are its package builds), or `None`
        for a program in no package.
      deps: List of targets providing `DartInfo`.

    Returns:
      List of unique `DartPackageInfo` records, the program's first.
    """
    return merge_package_records(
        ([package] if package != None else []) +
        depset(transitive = [dep[DartInfo].transitive_packages for dep in deps]).to_list(),
    )

def unique_data_assets(packages):
    """The data assets of `packages`, one per id.

    Args:
      packages: List of `DartPackageInfo`, merged as `collect_packages` merges them.

    Returns:
      `(assets, error)`: the list, the first package's first, and None; or
      None and an error string when two records of one package name
      different files for one id, since an application bundles one file per
      id.
    """
    by_id = {}
    for pkg in packages:
        for asset in package_data_assets(pkg):
            previous = by_id.get(asset.id)
            if previous == None:
                by_id[asset.id] = asset
            elif previous.file != asset.file:
                return None, (("data asset id `%s` names two files, `%s` and `%s`: " +
                               "two records of package `%s` declare it differently. " +
                               "An application bundles one file per id; declare the " +
                               "package's data assets once, on its " +
                               "`dart_package_metadata`.") %
                              (asset.id, previous.file.short_path, asset.file.short_path, asset.package))
    return by_id.values(), None

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
    return program_packages(None, deps)

def derived_pubspec(name, sdk, packages):
    """The `pubspec.yaml` a package's targets imply, for tools that read one.

    Some SDK tools and generators read a pubspec where the build states the
    same facts on its targets: lints read its name and dependencies, and
    `json_serializable` its dependency on `json_annotation`. rules_dart writes
    them this file instead of reading the user's, so a workspace needs none.
    Each dependency's constraint is the version the build uses when the record
    knows it (a pub package's), else `any`: nothing resolves the file, so the
    constraint only has to be true. Sorted, as `sort_pub_dependencies` wants.

    Args:
      name: The package's name.
      sdk: The `environment.sdk` constraint.
      packages: `DartPackageInfo` records of the packages it depends on. The
        package's own records are skipped; a package never depends on itself.

    Returns:
      The file's contents.
    """
    versions = {}
    for p in packages:
        if p.package_name and p.package_name != name:
            versions[p.package_name] = p.version or versions.get(p.package_name, "")
    lines = ["name: %s" % name, "environment:", '  sdk: "%s"' % sdk]
    if versions:
        lines.append("dependencies:")
        for dep in sorted(versions):
            lines.append("  %s: %s" % (dep, versions[dep] or "any"))
    return "\n".join(lines) + "\n"

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

# Within one repository every target of a package names one
# `dart_package_metadata`, so its records agree by construction; these fire for
# a package two producers supply (two pub hubs), or for records a rule builds
# with `DartPackageInfo()`.
_LICENSE_FILE_REMEDY = """
Each package listed just above has records naming different license files, so
which license text the package is reported with would be decided by dependency
order. Make the producers of those records state the same `license_file`, or
have only one of them state it.
"""

_LANGUAGE_VERSION_REMEDY = """
Each package listed just above has records stating different
`language_version`s, so the Dart semantics its sources compile under would be
decided by dependency order. Make the producers of those records state the same
`language_version`, or have only one of them state it.
"""

_LINK_HOOK_REMEDY = """
Each package listed just above has records naming different link hooks, so
which one runs would be decided by dependency order. A package has one
`hook/link.dart`: make the producers name the same `link_hook`, or only one of
them.
"""

_LINK_HOOK_ASSETS_REMEDY = """
Each package listed just above has records naming different data assets its
link hook emits. A package's hook emits what it emits: make the producers name
the same `link_hook_assets`, or only one of them.
"""

_BUILD_HOOK_REMEDY = """
Each package listed just above has records naming different build hooks. A
package has one `hook/build.dart`; make every producer that states one state
the same path.
"""

_METADATA_REMEDY = """
Every target of one package names the package's one `dart_package_metadata`
with `package`, so each of its records carries every fact the package states,
whichever target a program reaches. Set `package` on each target listed with
none, or point the targets listed above at the same `dart_package_metadata`.
"""

# The package-level facts two records of one package must agree on: how each
# record states it ("" when it states none), what the report calls it, and the
# remedy. `merge_package_records` takes each from whichever record states it,
# which is only order-independent because of this check.
_AGREED_FIELDS = (
    (lambda pkg: pkg.version, "versions", _VERSION_REMEDY),
    (lambda pkg: pkg.language_version, "language versions", _LANGUAGE_VERSION_REMEDY),
    (_license_key, "license files", _LICENSE_FILE_REMEDY),
    (_link_hook_key, "link hooks", _LINK_HOOK_REMEDY),
    (_link_hook_assets_key, "link-hook assets", _LINK_HOOK_ASSETS_REMEDY),
    (lambda pkg: pkg.unreplaced_hook, "build hooks", _BUILD_HOOK_REMEDY),
)

def _stated_by(pkg):
    """Names the target behind a record, and where its package is rooted."""
    root = pkg.package_root or "."
    label = pkg.label
    if label == None:
        return root
    return "%s at %s" % (label, root)

def derive_package_name(package_name_attr, label_package, label_name):
    """Derive the Dart package name from rule attributes and label.

    Without an explicit name, a package is named for its root directory: the
    Bazel package's last component, or for a BUILD file inside `lib/` the
    component above that `lib` (see `derive_package_root`). A root at the top of
    the workspace has no directory name, and takes the target's.

    Args:
        package_name_attr: Explicit package name attribute, or empty string.
        label_package: The Bazel label package path.
        label_name: The Bazel label name.

    Returns:
        The derived Dart package name.
    """
    if package_name_attr:
        return package_name_attr
    parts = label_package.split("/") if label_package else []
    if "lib" in parts:
        parts = parts[:parts.index("lib")]
    return parts[-1] if parts else label_name

def default_language_version(dart_sdk_info):
    """The language version of a package that states none: the SDK's own.

    A `package_config.json` entry without `languageVersion` is compiled at the
    SDK's current version, so that is the version such a package has. Every
    rule that must name it — a code generator's root package, the SDK
    constraint staged for the analyzer, the format check's style — takes it
    from here, so none can hold the package to another.

    Args:
      dart_sdk_info: The `DartSdkInfo` of the toolchain the action runs.

    Returns:
      The SDK version's `<major>.<minor>`, e.g. `3.12` for `3.12.2`.
    """
    major, minor = dart_sdk_info.version.split(".")[:2]
    return "%s.%s" % (major, minor)

def codegen_language_version(ctx, identity):
    """The language version a code generator runs its root package at.

    Args:
      ctx: The codegen rule's context (declares `PORTABLE_EXEC_GROUPS`).
      identity: The rule's `resolve_package_identity` result.

    Returns:
      The declared `language_version`, else `default_language_version`'s.
    """
    return identity.language_version or default_language_version(portable_sdk(ctx))

def package_identity_attrs(mandatory = False, doc = None):
    """The `package` attribute every rule that builds part of a Dart package gains.

    It points at the one `dart_package_metadata` that declares the package's
    facts. A rule merges the result into its `attrs`, so every rule set declares
    the same attribute and cannot drift from it.

    Args:
      mandatory: Whether the target must name a declaration. Unset, a target
        naming none is named after its root's directory and states nothing else.
      doc: The attribute's documentation, for a rule that says more of its
        package than the default does. The default describes the declaration.

    Returns:
      A dict with the one attribute, `package`.
    """
    return {
        "package": attr.label(
            providers = [DartPackageMetadataInfo],
            mandatory = mandatory,
            doc = doc or ("The `dart_package_metadata` declaring the Dart package this target is part of: its name, language version, license, hooks and code assets. Every target of a package names the same one." +
                          ("" if mandatory else " Unset, the target's package is named after its root's directory and states nothing else.")),
        ),
    }

def resolve_package_identity(ctx, metadata = None):
    """Resolves the package a rule's target is part of.

    From its `package` attribute, or from `metadata` when the declaration comes
    from elsewhere: a test built in its application's package names the
    application's.

    Args:
      ctx: The rule context. Declares `package` (`package_identity_attrs()`)
        unless `metadata` is passed.
      metadata: The `DartPackageMetadataInfo` the target belongs to, when it
        does not come from `package`. If the rule's `package` is also set it
        must name the same declaration, or the build fails.

    Returns:
      `struct(metadata, package_name, language_version, package_root,
      license_file)`. With a declaration: it and its facts, and its directory as
      `package_root`. Without one: `metadata` `None`, `package_name` the name of
      the target's root directory (`derive_package_name`), `language_version`
      "", `license_file` `None`, and `package_root` the root a `dart_library`
      in the target's BUILD directory would take (`derive_package_root`, which
      fails where `lib` makes it ambiguous). A library's own root is
      `library_package`'s, which also reads its files.
    """
    named = getattr(ctx.attr, "package", None)
    if named != None:
        named = named[DartPackageMetadataInfo]
        if metadata == None:
            metadata = named
        elif metadata.label != named.label:
            fail(("%s: `package` names %s, but the package this target belongs " +
                  "to is declared by %s. Drop `package`, or name the same " +
                  "declaration.") % (ctx.label, named.label, metadata.label))
    if metadata == None:
        return struct(
            metadata = None,
            package_name = derive_package_name("", ctx.label.package, ctx.label.name),
            language_version = "",
            package_root = derive_package_root(ctx.label.workspace_root, ctx.label.package),
            license_file = None,
        )
    return struct(
        metadata = metadata,
        package_name = metadata.package_name,
        language_version = metadata.language_version,
        package_root = metadata.package_root,
        license_file = metadata.license_file,
    )

def identity_package_record(label, identity, package_root):
    """The `DartPackageInfo` of a target of the package an identity names, rooted at `package_root`.

    Every fact comes from the declaration when there is one; otherwise the
    record has the name and the root and states nothing else.

    Args:
      label: The target's label, recorded as the record's `label`.
      identity: The target's `resolve_package_identity` result.
      package_root: Where the package's sources are.

    Returns:
      A `DartPackageInfo`.
    """
    if identity.metadata != None:
        return package_info_from_metadata(label, identity.metadata, package_root)
    return DartPackageInfo(
        label = label,
        package_name = identity.package_name,
        package_root = package_root,
        language_version = "",
    )

def executable_package_record(label, identity):
    """The `DartPackageInfo` of an executable that is part of the package an identity names.

    An executable belongs to its package wherever its BUILD file is, so the
    record is rooted at the identity's `package_root`: the declaration's
    directory, or the target's own when it names none.

    Args:
      label: The executable's label, recorded as the record's `label`.
      identity: Its `resolve_package_identity` result.

    Returns:
      A `DartPackageInfo`, the one a `dart_library` of the same declaration
      builds, rooted at the same place.
    """
    return identity_package_record(label, identity, identity.package_root)

def codegen_identity(identity):
    """The `DartPackageMetadataInfo` a codegen rule returns for the library collecting its outputs.

    The declaration it names, or, when it names none, one with only the
    package name its directory gives it, so `codegen_identity_error` can tell
    the two cases apart.

    Args:
      identity: The codegen rule's `resolve_package_identity` result.

    Returns:
      A `DartPackageMetadataInfo`.
    """
    if identity.metadata != None:
        return identity.metadata
    return DartPackageMetadataInfo(
        label = None,
        package_name = identity.package_name,
        package_root = "",
        language_version = "",
        version = "",
        code_assets = (),
        data_assets = (),
        unreplaced_hook = "",
        link_hook = None,
        link_hook_assets = (),
        linked_code_assets = (),
        license_file = None,
    )

def _declared_by(metadata_label, package_name):
    if metadata_label == None:
        return "package \"%s\", which names no `dart_package_metadata`" % package_name
    return "the package `%s` declares" % metadata_label

def codegen_identity_error(label, srcs, package_name, metadata):
    """Reports a generated source whose package contradicts its library's.

    A codegen rule and the library collecting its outputs each name the package
    the generated file belongs to. They cannot be made to agree by
    construction: the library depends on the codegen's output, so no provider
    reaches from the codegen to the library, and the two are routinely written
    in different BUILD files. `srcs` is where they meet. Both must name the
    same `dart_package_metadata`, or, naming none, the same package name.

    Args:
      label: The consuming rule's label, for the error message.
      srcs: The consuming rule's `srcs` targets (`ctx.attr.srcs`).
      package_name: The consuming rule's package name.
      metadata: The `DartPackageMetadataInfo` the consuming rule names, or None.

    Returns:
      An error message string, or `None` when nothing contradicts.
    """
    own = metadata.label if metadata != None else None
    for src in srcs:
        if DartPackageMetadataInfo not in src:
            continue
        generated = src[DartPackageMetadataInfo]
        if generated.label == own and (own != None or generated.package_name == package_name):
            continue
        return (
            ("%s: generates sources for %s, but %s collects them into %s. A " +
             "generated file is part of the package whose sources it was " +
             "generated from, so both must name the same `dart_package_metadata` " +
             "with `package`.") % (
                src.label,
                _declared_by(generated.label, generated.package_name),
                label,
                _declared_by(own, package_name),
            )
        )
    return None

def package_agreement_error(merged):
    """Reports every duplicate record that states facts its twin contradicts.

    Two records for one `package_name` are normal — see `merge_package_records`
    for why — but they are supposed to describe the *same* package. Were they
    to disagree, `merge_package_records` would keep one and silently discard
    the other: for `version`, one version's entire source tree substituted for
    the other's, which a skewed pair of lock files reproduces; for
    `language_version`, the package compiled under semantics one of its
    targets did not state; for `link_hook`, one hook run and the other
    skipped.

    The fields are the package's own facts: `version`, `language_version`,
    `license_file`, `link_hook`, `link_hook_assets` and `unreplaced_hook`.
    Only two *stated* values can disagree. A record that states none carries
    "" (or `None`, or `()`) — every
    `DartPackageInfo` built by a rule set that predates the field, every
    hand-written `dart_library`, which has no version to state, and every
    target of a split package but the one carrying the hook or the license.
    Treating "" as a disagreement would fail every dual-hub build including
    the agreeing ones; treating it as "knows less" is what lets the merge take
    the fact from whichever record states it.

    The license file and link hook are compared by their path within the
    package rather than as Files, for the reason `_in_package_key` gives. Each
    value is reported with the target that stated it first, from the record's
    `label`, and the package root, which tells two pub hubs apart.

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

    # Targets naming different declarations of one package is the cause of
    # any value they disagree on, so it is reported alone.
    err = _metadata_agreement_error(merged)
    if err != None:
        return err
    blocks = []
    for read, label, remedy in _AGREED_FIELDS:
        # value -> the first record stating it, per package name.
        stated = {}
        for pkg in merged:
            value = read(pkg)
            if not value:
                continue
            seen = stated.setdefault(pkg.package_name, {})
            if value not in seen:
                seen[value] = _stated_by(pkg)

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

def _metadata_agreement_error(merged):
    """Reports records at one root that name different declarations.

    A root has one `dart_package_metadata`, so every record rooted there that
    names one names the same, whatever package name each declaration states:
    two declarations for one root, in one BUILD file or one at the root and one
    under `lib/`, are refused wherever their targets meet. A record naming none
    is refused beside a declaration of its own package name. Records at
    different roots (two pub hubs each supplying a package) are compared by
    value instead.
    """

    # root -> {metadata label: first record naming it}, and
    # root -> {package name: first record naming no declaration}
    declared = {}
    undeclared = {}
    order = []
    for pkg in merged:
        root = pkg.package_root
        if root not in declared:
            declared[root] = {}
            undeclared[root] = {}
            order.append(root)
        if pkg.metadata != None:
            declared[root].setdefault(pkg.metadata, pkg)
        else:
            undeclared[root].setdefault(pkg.package_name, pkg)
    reported = []
    for root in order:
        names = {pkg.package_name: True for pkg in declared[root].values()}
        clashes = [pkg for name, pkg in undeclared[root].items() if name in names]
        if len(declared[root]) < 2 and not clashes:
            continue
        entries = [(str(m), pkg) for m, pkg in declared[root].items()] + [("none", pkg) for pkg in clashes]
        reported.append(
            "The package rooted at `%s` is built by targets naming different `dart_package_metadata`:\n" % (root or ".") +
            "".join([
                "  - %s (package \"%s\"), named by %s\n" % (
                    m,
                    pkg.package_name,
                    pkg.label if pkg.label != None else "a target",
                )
                for m, pkg in sorted(entries, key = lambda e: "" if e[0] == "none" else e[0])
            ]),
        )
    if not reported:
        return None
    return "".join(reported) + _METADATA_REMEDY

def _first_stated(records, read, empty):
    for pkg in records:
        value = read(pkg)
        if value != empty:
            return value
    return empty

def merge_package_records(merged):
    """Dedups package records by name, combining what each one states.

    One `package_name` can legitimately appear with several records:

      * a package split across `dart_library` targets — Gazelle's
        per-directory layout, and the case `colocate_packages` exists to
        serve — whose records name one `dart_package_metadata` and so state
        the same facts; and
      * a package supplied independently by two pub hubs, e.g. rules_flutter's
        `flutter.pub()` and rules_dart's `pub.from_lock()` both generating a
        spoke for `ffi`, rooted apart.

    The merged record is the first record, for source resolution, with every
    package-level fact taken from whichever record states it: `version`,
    `language_version`, `license_file`, `link_hook`, `link_hook_assets` and
    `unreplaced_hook`. A producer that states fewer facts (an older one, or a
    rule set adopting a field on its own schedule) knows less, so a fact
    stated on any record is the package's. Taking the first stated value is order-independent only
    because the records agree, so this calls `package_agreement_error` first
    and fails, naming both targets, when two records at one root name
    different declarations or two records state different values of any of
    those fields.

    Code and data assets union instead, each once: dropping a later record's
    assets would silently lose a native library, and the failure would surface
    at runtime as an unresolved `@Native` symbol. `resolve_code_assets` and
    `unique_data_assets` fail later if — and only if — two assets
    genuinely claim one id, which is the case the Dart VM cannot resolve either.
    Assets replace a build hook, so the merged package's hook is unreplaced
    when any record names one and no record supplies assets: a hub curating
    `code_assets` replaces the hook another hub still flags.

    Split out from `collect_packages` because the dedup and union rules are a
    pure function of the record list, which makes them directly testable
    without synthesising `DartInfo`-bearing targets. The agreement check keeps
    that property by living in its own function and returning its message.
    `merged_package_record` is the same merge for a target that is itself a
    package.

    Args:
        merged: List of DartPackageInfo, with duplicates, in dependency order.

    Returns:
        List of unique DartPackageInfo providers in dependency order.
    """
    err = package_agreement_error(merged)
    if err != None:
        fail(err)

    names = []
    records_by_name = {}
    for pkg in merged:
        records = records_by_name.get(pkg.package_name)
        if records == None:
            names.append(pkg.package_name)
            records_by_name[pkg.package_name] = [pkg]
        else:
            records.append(pkg)
    return [_merge_one(records_by_name[name]) for name in names]

def _merge_one(records):
    """The first of one package's agreeing records, completed from the others."""
    kept = records[0]
    if len(records) == 1:
        return kept
    code_assets = []
    for pkg in records:
        for asset in package_code_assets(pkg):
            if asset not in code_assets:
                code_assets.append(asset)
    code_assets = tuple(code_assets)
    data_assets = []
    for pkg in records:
        for asset in package_data_assets(pkg):
            if asset not in data_assets:
                data_assets.append(asset)
    data_assets = tuple(data_assets)
    linked_code_assets = []
    for pkg in records:
        for asset in package_linked_code_assets(pkg):
            if asset not in linked_code_assets:
                linked_code_assets.append(asset)
    merged = derived_package_info(
        kept,
        version = _first_stated(records, lambda p: p.version, ""),
        language_version = _first_stated(records, lambda p: p.language_version, ""),
        code_assets = code_assets,
        data_assets = data_assets,
        unreplaced_hook = "" if code_assets or data_assets or linked_code_assets else _first_stated(records, lambda p: p.unreplaced_hook, ""),
        link_hook = _first_stated(records, package_link_hook, None),
        link_hook_assets = _first_stated(records, package_link_hook_assets, ()),
        linked_code_assets = tuple(linked_code_assets),
        license_file = _first_stated(records, package_license_file, None),
    )

    # A record that already states everything the others do is kept as it is,
    # so a duplicate that adds nothing leaves the record unchanged.
    if merged == derived_package_info(kept):
        return kept
    return merged

def merged_package_record(label, package_name, package_root, metadata, records):
    """The record of a target that is itself a package, completed from the records at its root.

    A target whose own sources are a package's `lib/` — a downstream app or
    test rule — can depend on `dart_library` targets rooted at the same
    directory. They are the same package, and one directory can be only one
    package in a `package_config.json`, so the target contributes one record
    in place of theirs: this target's merged with theirs, by
    `merge_package_records`. Every record of the package names the same
    `dart_package_metadata`, this target's included, so their facts agree by
    construction; a target naming none merges only with records naming none.
    With no records at the root it is this target's own.

    Args:
      label: The target's label, recorded on the result and named in errors.
      package_name: The package's name: `metadata.package_name`, or, when the
        target names no declaration, its directory's (`derive_package_name`).
      package_root: The package root, the target's own (`derive_package_root`).
      metadata: The `DartPackageMetadataInfo` the target names, or `None`.
      records: The `DartPackageInfo` records already rooted at
        `package_root`, e.g. those of `collect_packages(deps)` whose
        `package_root` is it. Each must be named `package_name`: a directory
        is one package.

    Returns:
      A `DartPackageInfo`.
    """
    if metadata != None and metadata.package_name != package_name:
        fail(("%s: `merged_package_record` was given package \"%s\" and the " +
              "declaration %s of package \"%s\". Pass the declaration's " +
              "`package_name`.") % (label, package_name, metadata.label, metadata.package_name))
    for pkg in records:
        if pkg.package_root != package_root or pkg.package_name != package_name:
            fail(("%s: `merged_package_record` was given package \"%s\" rooted " +
                  "at `%s`, stated by %s, for package \"%s\" rooted at `%s`. " +
                  "Pass only the records rooted at the package's own root, " +
                  "and report a differently named one to the user — one " +
                  "directory is one package.") % (
                label,
                pkg.package_name,
                pkg.package_root or ".",
                _stated_by(pkg),
                package_name,
                package_root or ".",
            ))
    if metadata != None:
        own = package_info_from_metadata(label, metadata, package_root)
    else:
        own = DartPackageInfo(
            label = label,
            package_name = package_name,
            package_root = package_root,
            language_version = "",
        )
    return merge_package_records([own] + list(records))[0]

EMPTY_PACKAGE_CONFIG_ATTR = {
    "_empty_package_config": attr.label(
        doc = "A package config naming no packages, passed to the VM as `--packages`.",
        default = "//dart/private/tools:empty_package_config.json",
        allow_single_file = True,
    ),
}

def empty_package_config(ctx):
    """The package config a launched program is given as `--packages`: one naming no package.

    A launcher that passes it stops the VM looking for a package config up from
    the program, where outside a sandbox it finds the workspace's own
    `.dart_tool` through the exec root. Add the file to the launcher's runfiles
    and pass its `runfiles_path`.

    Args:
      ctx: Rule context carrying `_empty_package_config`.

    Returns:
      The `File`.
    """
    return ctx.file._empty_package_config

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
# its `cross_tools` names. `@rules_dart//dart`, which starts `dart` for the
# user, sets it too: the home is then the user's own.
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
    """Checks that at most one package claims the empty (root) `package_root`.

    Two or more empty-package_root packages are ambiguous: the empty-prefix match
    would race to claim any `lib/`-prefixed source.

    Args:
        packages: List of DartPackageInfo providers.

    Returns:
        An error message string when more than one package has an empty
        `package_root`, else `None`.
    """
    root_names = [pkg.package_name for pkg in packages if not pkg.package_root]
    if len(root_names) > 1:
        return (
            "Multiple packages declare an empty `package_root`: %s. Each " +
            "Bazel build graph can only attribute `lib/...` sources to " +
            "one root package."
        ) % ", ".join(root_names)
    return None

def resolve_package_exec_roots(packages, all_srcs):
    """Match packages to source files, returning exec-root-relative roots.

    Ownership is `package_for`'s and only `package_for`'s: a file resolves a
    package's root only if it is one the package could actually export — under
    `<package_root>/lib/`, or the `package_root` directory itself. Matching anything
    else under `package_root` was the bug: a `dart_test` sitting in the same Bazel
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

    Two or more packages with an empty `package_root` are ambiguous — the
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

        roots[name] = package_exec_root(src, by_name[name].package_root)
    return roots

def package_exec_root(src, package_root):
    """Returns the exec-root-relative root of the package `src` belongs to.

    Args:
        src: A File the package owns (see `package_for`).
        package_root: The owning package's `package_root`.

    Returns:
        The exec path of the package root directory.
    """

    # The package-relative tail, stripped off the exec path to leave the
    # root. Empty when the file *is* the package root (an assembled
    # directory); otherwise "/lib/…", or "lib/…" for the root package,
    # whose empty `package_root` leaves a trailing slash to trim.
    suffix = src.short_path[len(package_root):]
    exec_root = src.path[:len(src.path) - len(suffix)]
    if exec_root.endswith("/"):
        exec_root = exec_root[:-1]
    return exec_root

def generate_package_config(packages, all_srcs, config_file):
    """Generate package_config.json content using short_path-based package_root.

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

    exec_roots = resolve_package_exec_roots(packages, all_srcs)
    config_dir = config_file.dirname

    entries = []
    for pkg in packages:
        exec_root = exec_roots.get(pkg.package_name)
        if exec_root != None:
            root_uri = relative_path(config_dir, exec_root)
        elif not pkg.package_root:
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
        if pkg.language_version:
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
    emits a `<scheme>:///<package_root>` `rootUri` for each such package and reports
    the filesystem roots the frontend_server must search (`--filesystem-root`,
    `--filesystem-scheme`) to resolve those scheme URIs across BOTH the live
    source tree and the generated `bazel-out` outputs. Non-assembled packages
    (pub deps, pure source packages) keep their normal relative `rootUri` —
    the frontend_server resolves a mix of scheme and relative `rootUri`s.

    Args:
        packages: List of DartPackageInfo providers (pre-colocation, so the app
            package still has its real `package_root`).
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
          source_packages: (name, package_root) for each package contributing a
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

    exec_roots = resolve_package_exec_roots(packages, all_srcs)
    config_dir = config_file.dirname

    # First-party source packages (name, package_root) the dev tool can map a live
    # edit back to: any package contributing an `is_source` file that lives in
    # the main repo (short_path not under `external/` or `../<repo>`). Excludes
    # pub/external deps (not editable, never watched) and generated-only
    # packages. `package_root` is short_path-relative, i.e. workspace-relative, so
    # the dev tool resolves a path to `package:<name>/<rel>` without inverting
    # rootUris — see the dev tool's PackageUriResolver.
    source_packages = []
    for pkg in packages:
        for f in by_pkg.get(pkg.package_name, []):
            if (f.is_source and
                not f.short_path.startswith("external/") and
                not f.short_path.startswith("../")):
                source_packages.append((pkg.package_name, pkg.package_root))
                break

    source_roots = []
    generated_roots = []
    generated_source_paths = []
    generated_source_uris = []
    entries = []
    for pkg in packages:
        files = by_pkg.get(pkg.package_name, [])
        if needs_source_assembly(files):
            root_uri = "{scheme}:///{package_root}".format(
                scheme = scheme,
                package_root = pkg.package_root,
            )
            lib_prefix = package_lib_prefix(pkg.package_root)
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
            elif not pkg.package_root:
                root_uri = relative_path(config_dir, "")
            else:
                continue
        lv = ""
        if pkg.language_version:
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
    where config is at .dart_tool/ and packages are at ../<package_root>).

    Args:
        packages: List of DartPackageInfo providers.
        prefix: Path prefix to prepend to each package's package_root for rootUri.

    Returns:
        String content of the package_config.json file.
    """
    if not packages:
        return '{"configVersion": 2, "packages": []}\n'

    entries = []
    for pkg in packages:
        root_uri = prefix + "/" + pkg.package_root if pkg.package_root else prefix
        lv = ""
        if pkg.language_version:
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

def collect_transitive_runfiles(ctx, deps):
    """The runfiles (`data`) the libraries of `deps` and theirs need at run time.

    Args:
        ctx: The rule context.
        deps: List of targets providing DartInfo.

    Returns:
        A runfiles object, empty when none needs any.
    """

    # `getattr`: a provider built before the field existed has none.
    return ctx.runfiles().merge_all([
        dep[DartInfo].runfiles
        for dep in deps
        if getattr(dep[DartInfo], "runfiles", None) != None
    ])

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

    What a codegen generator is given as `--sdk-path`, and the SDK summary
    actions as `--sdk`.

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

def synth_package_config(ctx, packages, srcs, resources):
    """Synthesises a codegen action's `package_config.json` from the packages it reads.

    Args:
      ctx: The rule context (used to declare the output file).
      packages: The `DartPackageInfo` records of every package the
        generator may read.
      srcs: A depset of their Dart sources.
      resources: A depset of their other files under `lib/`.

    Returns:
      `(package_config_file, package_files_depset)`, or `(None, None)`
      when `packages` is empty. The depset holds every file of every
      package the config names, sources and `resources` alike: a generator
      may read any of them through the config, so the caller adds both to
      the action's `inputs` (the depset flattens lazily at execution time).
    """
    if not packages:
        return None, None
    package_files = depset(transitive = [srcs, resources])
    package_config = ctx.actions.declare_file(
        ctx.label.name + ".package_config.json",
    )

    # generate_package_config needs a list of File (not a depset) because
    # it performs per-file path matching. Materialising here is bounded
    # by the dep graph size for this one target, not by the action count.
    content = generate_package_config(
        packages,
        srcs.to_list(),
        package_config,
    )
    ctx.actions.write(output = package_config, content = content)
    return package_config, package_files

# --- Native code-asset (frontend_server --native-assets) helpers ---

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
    "dynamic_loading_system": ("system", "uri"),
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

def native_assets_path_list(label, link_mode, relative_lib_path, uri):
    """Returns the VM path-list for one code asset, per its link mode.

    Args:
      label: The consuming target's label, for error messages.
      link_mode: One of `CODE_ASSET_LINK_MODES`.
      relative_lib_path: Path to the library relative to the dill, for
        `dynamic_loading_bundle`.
      uri: The system library URI, for `dynamic_loading_system`.

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
    if payload == "uri":
        return [path_type, uri]
    return [path_type]

def check_unreplaced_hooks(label, packages):
    """Checks that no package in the closure has an unreplaced build hook.

    A package shipping `hook/build.dart` (a pub package, or a
    `dart_package_metadata` stating its `build_hook`) builds native libraries at `pub get` time. rules_dart cannot run that hook, so without a Bazel
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
        if pkg.unreplaced_hook
    ]
    if not offenders:
        return None
    lines = []
    curated = False
    for pkg in offenders:
        line = "  - %s (%s)" % (pkg.package_name, pkg.unreplaced_hook)
        versions = curated_versions(pkg.package_name)
        if versions:
            curated = True
            line += "; rules_dart builds pub's `%s` at %s" % (pkg.package_name, " or ".join(versions))
        lines.append(line)
    return (
        ("%s depends on package(s) that build assets with a hook " +
         "rules_dart does not run:\n%s\n\n" +
         "Their `@Native` bindings will not resolve at runtime, and their data " +
         "assets will be missing. A target's own `code_assets` do not replace a " +
         "package's hook; the package's must.\n" +
         "  - For your own package: build the native code with Bazel and " +
         "name its `dart_code_asset` in the `code_assets` of the package's " +
         "`dart_package_metadata`, and each file the hook emits as a data " +
         "asset as a `dart_data_asset` in its `data_assets`; or remove its " +
         "`build_hook` if what it builds is genuinely unused here.\n" +
         "  - For a pub package: if its native code is genuinely unused here, list " +
         "it in `pub.from_lock(ignore_hooks = [...])` or set " +
         "`pub.package(ignore_hook = True)`; otherwise map it with " +
         "`pub.from_lock(resolve = {...})` to a `dart_library` of the package " +
         "whose `dart_package_metadata` names its `code_assets`.%s") %
        (label, "\n".join(lines), (
            "\n  - For a pub package rules_dart builds at other versions " +
            "(noted above): pin it to one of those versions in your lock or " +
            "`pub.package()`, and rules_dart attaches its replacement."
        ) if curated else "")
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
    library = asset.file.path if asset.file != None else ""
    return (asset.link_mode, asset.uri, library)

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
                previous.file != None and asset.file != None and
                previous.file.owner == asset.file.owner
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
                 "that setting before the library") % asset.file.owner if same_target else "drop one of the declarations",
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
        if info.file != None:
            relative_lib_path = relative_path(output_dir, info.file.path)
            if info.file not in libraries:
                libraries.append(info.file)
        entries.append((
            info.asset_id,
            native_assets_path_list(label, info.link_mode, relative_lib_path, info.uri),
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
        library = asset.file
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
            file = links[library],
            uri = asset.uri,
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
      short_path: A `File.short_path`, or a `package_root`.

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

def _sdk_root(platform):
    return platform.dirname + "/"

def dart_kernel_action(
        ctx,
        kernel_sdk,
        runtime,
        main,
        srcs,
        package_config,
        output_dill,
        entrypoint_uri = None,
        sources = [],
        filesystem_scheme = KERNEL_FILESYSTEM_SCHEME,
        defines = [],
        flags = [],
        native_assets = None,
        track_creation_locations = False,
        outputs = {},
        kernel_tool = None,
        resource_set = kernel_resources):
    """Runs the Dart front end (`frontend_server`) to produce a whole program's kernel `.dill`.

    Every VM compile goes through here first, and `dart compile` then turns the
    kernel into a snapshot or executable; another platform's compile (Flutter's)
    is the same action given that platform's `kernel_sdk`. The front end names
    each library that is not in a package by its URI, and the compiled program
    keeps those URIs: in stack traces, and in the private-name suffixes derived
    from them, which reach every part of the output. `dart compile` given a
    source path names the entrypoint `file:///<absolute path>`, so the bytes
    depended on where the action ran — the sandbox directory, the output base.
    Here the sources are read through `filesystem_scheme`, rooted at the exec
    root and the output directories the sources lie in (`add_kernel_roots`), so
    the entrypoint is `<scheme>:///<path in the workspace>` wherever and in
    whichever configuration it was built, and its relative imports resolve
    within those roots exactly as they do on disk. `package_config` names its
    packages the same way (`kernel_package_config`).

    Everything about the platform comes from `kernel_sdk`: the compiler and
    the runtime it runs on, the target, and, for the `runtime` asked for, the
    platform dill, the declarations that runtime fixes (for the VM those
    `dart compile` passes, `dart.vm.product` and the sanitizer defines, which
    are false in a released SDK) and its front-end flags. The declarations are
    constants the front end folds, so they have to be right here; the step
    after sees only the folded result.

    The kernel names its sources under `filesystem_scheme`, never by a path of
    the machine, which is what makes it the same from any output base. A tool
    that wants a source's path on disk from the compiled program therefore
    gets none: `gen_snapshot --resolve-dwarf-paths`, which turns each resolved
    URI into a path for DWARF, accepts only `file:` and two SDK schemes and
    stops with "cannot convert resolved URI" on any other. DWARF without that
    flag names each source by its URI and works.

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
    by a `dart_binary`; the targets that build it compile with
    `bootstrap_kernel_action` instead.

    A kernel is the same whichever host compiles it, so this runs in
    `PORTABLE`, and `kernel_sdk` is built for that host.

    Args:
      ctx: The rule context; the rule declares `PORTABLE_EXEC_GROUPS`.
      kernel_sdk: The `DartKernelSdkInfo` of the platform.
      runtime: The name of the entry of `kernel_sdk.runtimes` the kernel is
        for.
      main: The entrypoint `.dart` File.
      srcs: Depset of every source File the program reads besides `main`.
      package_config: The `kernel_package_config` File, or None.
      output_dill: The output `.dill` File to produce.
      entrypoint_uri: The URI the front end compiles as the root library,
        which fixes that library's `importUri`: a `package:` URI, or one under
        `filesystem_scheme`. None compiles `main` under `filesystem_scheme` at
        its path in the workspace.
      sources: URIs of further libraries to compile into the program beside
        the entrypoint (`--source`), each a `package:` URI or one under
        `filesystem_scheme`; their files are among `srcs`.
      filesystem_scheme: The scheme the sources, `package_config` and
        `package_config`'s packages are read through. One that a compiler
        elsewhere also uses (a dev loop's, for hot reload) names the
        libraries outside packages the same way for both.
      defines: Environment declarations; each entry becomes a `-D` flag. This
        action runs the front end, so it is the only stage where they can still
        reach constant evaluation.
      flags: Further front-end flags, e.g. `--enable-experiment=...`; those
        `frontend_server` accepts.
      native_assets: Optional native assets mapping File
        (`native_assets.yaml`, or the `native_assets.json` a bundler writes),
        embedded as the `vm:ffi:native-assets` mapping. The libraries it names
        are a run-time (runfiles) dependency, not inputs.
      track_creation_locations: Whether to pass `--track-creation-locations`,
        which the whole program, here, is compiled with or without.
      outputs: Further files the compiler writes, by the flag that names each
        (`{"--recorded-uses": file}`).
      kernel_tool: The `kernel_tool` executable to run the front end through.
      resource_set: What the compile uses, for Bazel's local scheduler: a
        top-level function as `ctx.actions.run` takes it. The front end holds
        the whole program in memory, so a large one states more than the
        default.
    """
    if runtime not in kernel_sdk.runtimes:
        fail("%s: the `%s` platform has no runtime %r; it has %s" % (
            ctx.label,
            kernel_sdk.target,
            runtime,
            ", ".join(sorted(kernel_sdk.runtimes)),
        ))
    platform = kernel_sdk.runtimes[runtime]

    args = ctx.actions.args()
    args.add(kernel_sdk.frontend_server)
    args.add_all([platform.platform], before_each = "--sdk-root", map_each = _sdk_root)
    args.add("--platform", platform.platform.basename)
    args.add("--target", kernel_sdk.target)
    args.add_all(platform.defines, format_each = "-D%s")
    args.add("--no-print-incremental-dependencies")
    args.add("--filesystem-scheme", filesystem_scheme)
    add_kernel_roots(args, "--filesystem-root", depset([main], transitive = [srcs]))
    if package_config != None:
        args.add_all([package_config], before_each = "--packages", format_each = filesystem_scheme + ":///%s")
    if native_assets != None:
        args.add("--native-assets", native_assets)
    for d in defines:
        args.add("-D" + d)
    if track_creation_locations:
        args.add("--track-creation-locations")
    args.add_all(sources, before_each = "--source")
    args.add_all(platform.flags)
    args.add_all(flags)
    for flag, output in outputs.items():
        args.add(flag, output)
    args.add("--output-dill", output_dill)
    args.add(entrypoint_uri or filesystem_scheme + ":///" + kernel_root_path(main.short_path))

    # The front end reads only the files it is named: its snapshot, the
    # runtime and the platform.
    direct = [main, kernel_sdk.aot_runtime, kernel_sdk.frontend_server, platform.platform]
    if package_config != None:
        direct.append(package_config)
    if native_assets != None:
        direct.append(native_assets)

    launch = ctx.actions.args()
    launch.add("frontend")
    launch.add("--runtime", kernel_sdk.aot_runtime)
    launch.add("--")
    ctx.actions.run(
        executable = kernel_tool,
        arguments = [launch, args],
        inputs = depset(direct = direct, transitive = [srcs, kernel_sdk.tool_files]),
        outputs = [output_dill] + outputs.values(),
        mnemonic = "DartKernel",
        resource_set = resource_set,
        exec_group = PORTABLE,
        progress_message = "Compiling Dart kernel %s" % ctx.label,
        env = SDK_ENV,
        execution_requirements = PATH_MAPPING,
    )

# What every VM kernel declares besides `dart.vm.product`: the sanitizer
# defines, false in a released SDK. `dart compile` passes the same
# (`generateKernelHelper` in `pkg/dart2native`).
VM_SANITIZER_DEFINES = ["dart.vm.asan=false", "dart.vm.msan=false", "dart.vm.tsan=false"]

def _bootstrap_tools(dart_sdk_info):
    # The VM's own files by their place in the SDK: the programs compiled here
    # are rules_dart's tools, which run on the VM of the SDK they build with.
    root = sdk_path_from_dart(dart_sdk_info.dart) + "/"
    wanted = {
        "runtime": [root + "bin/dartaotruntime", root + "bin/dartaotruntime.exe"],
        "gen_kernel": [root + "bin/snapshots/gen_kernel_aot.dart.snapshot"],
        "platform": [root + "lib/_internal/vm_platform_product.dill"],
    }
    found = {}

    # Once per configuration: a probe for three files.
    for f in depset(transitive = [dart_sdk_info.files.aot_compile, dart_sdk_info.files.kernel]).to_list():
        for key, paths in wanted.items():
            if f.path in paths:
                found[key] = f
    missing = [k for k in wanted if k not in found]
    if missing:
        fail("could not find %s in the Dart %s SDK at %s" % (", ".join(missing), dart_sdk_info.version, root))
    return struct(**found)

def bootstrap_kernel_action(ctx, main, srcs, package_config, output_dill, defines = [], flags = []):
    """Compiles one of rules_dart's own tools to a kernel, where `kernel_tool` cannot run.

    `kernel_tool`, which runs every other compile, is itself a program, so it
    and the tools built alongside it (`dart_tool_binary`,
    `dart_bootstrap_binary`) are compiled without it. `frontend_server` prints
    its protocol on every success, so they are compiled by `gen_kernel`, the
    same front end without the protocol, which prints only diagnostics. It
    splits a `-D` value on commas, which these tools' declarations never
    contain; one that does is refused rather than cut short. The sources are
    read through `KERNEL_FILESYSTEM_SCHEME`, as in `dart_kernel_action`, so the
    kernel names no path of the machine.

    Args:
      ctx: The rule context; the rule declares `PORTABLE_EXEC_GROUPS`.
      main: The entrypoint File.
      srcs: Depset of every source File the program reads besides `main`.
      package_config: The `kernel_package_config` File.
      output_dill: The `.dill` File to produce.
      defines: Environment declarations, none with a comma.
      flags: Further front-end flags, those `gen_kernel` accepts.
    """
    for d in defines:
        if "," in d:
            fail("%s: `%s` has a comma, which `gen_kernel` would split; a tool built without `kernel_tool` cannot take it" % (ctx.label, d))
    tools = _bootstrap_tools(portable_sdk(ctx))
    args = ctx.actions.args()
    args.add(tools.gen_kernel)
    args.add("--platform", tools.platform)
    args.add("--target", "vm")
    args.add("-Ddart.vm.product=true")
    args.add_all(VM_SANITIZER_DEFINES, format_each = "-D%s")
    args.add("--filesystem-scheme", KERNEL_FILESYSTEM_SCHEME)
    add_kernel_roots(args, "--filesystem-root", depset([main], transitive = [srcs]))
    args.add_all([package_config], before_each = "--packages", format_each = KERNEL_FILESYSTEM_SCHEME + ":///%s")
    args.add_all(defines, format_each = "-D%s")
    args.add_all(flags)
    args.add("--output", output_dill)
    args.add(KERNEL_FILESYSTEM_SCHEME + ":///" + kernel_root_path(main.short_path))
    ctx.actions.run(
        executable = tools.runtime,
        arguments = [args],
        inputs = depset([main, package_config, tools.runtime, tools.gen_kernel, tools.platform], transitive = [srcs]),
        outputs = [output_dill],
        mnemonic = "DartKernel",
        resource_set = kernel_resources,
        exec_group = PORTABLE,
        progress_message = "Compiling Dart kernel %s" % ctx.label,
        env = SDK_ENV,
        execution_requirements = PATH_MAPPING,
    )

def asset_path_for(file, package_root):
    """Computes the in-package asset path for a File.

    Strips `package_root` (plus the trailing `/`) from the short_path. When
    `package_root` is empty the short_path is returned unchanged — that's the
    root-package case and the file's short_path IS its asset path.

    Generated files need one extra step first: `declare_file` paths are
    relative to the *producing rule's* Bazel package, so when a codegen
    target lives in a different Bazel package than the Dart package root,
    the generated short_path is `owner.package + "/" + declared_path`
    where `declared_path` embeds the source's short_path (`dart_codegen`
    declares outputs source-relative). Stripping `owner.package` and then
    `package_root` recovers the in-package asset path. When the declared path
    does not start with `package_root` (the codegen target's package is at or
    below the Dart package root with a same-package src), the generated
    short_path mirrors a source file's and the plain `package_root` strip
    below stays correct.

    Fails loudly when neither derivation matches: the unmatched short_path
    would give `--input-asset` / `--dep` values that resolve to no `package:`
    URI, and the builder would produce no output or an unhelpful
    `AssetNotFoundException`.

    Args:
      file: The File to compute the asset path for.
      package_root: The Dart package's short_path prefix (empty for the root
        workspace; e.g. `external/pub_deps++pub+foo` for external pub
        packages).

    Returns:
      The asset path string (relative to the Dart package root).
    """
    rel = file.short_path
    if not package_root:
        return rel
    if not file.is_source and file.owner != None:
        pkg_prefix = file.owner.package + "/" if file.owner.package else ""
        if pkg_prefix and rel.startswith(pkg_prefix):
            declared = rel[len(pkg_prefix):]
            if declared.startswith(package_root + "/"):
                return declared[len(package_root) + 1:]
    if rel.startswith(package_root + "/"):
        return rel[len(package_root) + 1:]
    fail(
        ("asset_path_for: file %r (short_path %r) is not under " +
         "package_root %r. Every codegen input / asset_dep must live inside " +
         "the Dart package's package_root — check that the owning " +
         "`dart_library` target for this file names the right " +
         "`dart_package_metadata`, or pass the file through `deps` instead. For " +
         "generated files, declare the producing codegen target in a " +
         "BUILD file at (or below) the Dart package root so its declared " +
         "output path resolves inside the package.") %
        (file.path, rel, package_root),
    )

def dart_package_root_for_package(packages, package_name):
    """Looks up the Dart package's package_root among the packages a generator reads.

    The first record whose `package_name` matches wins.

    The rule layer uses this to compute asset paths that survive the
    codegen rule living at a deeper Bazel-package path than the Dart
    package root (e.g. `//myapp/lib:codegen` where the Dart package is
    `//myapp`).

    Args:
      packages: `DartPackageInfo` records.
      package_name: The Dart package name to look up.

    Returns:
      The package_root string (possibly `""` for the root workspace package),
      or `None` when no matching package is found.
    """
    for pkg in packages:
        if pkg.package_name == package_name:
            return pkg.package_root
    return None

def same_package_library_dep_files(packages, files, package_name, exclude_paths = None):
    """Returns the files of package `package_name` among those a generator reads.

    Sources and `resources` alike: the files at `<package_root>/lib/...` of
    the package named `package_name`. Files whose exec path is in
    `exclude_paths` (e.g. the action's own `src` file) are skipped so the
    input isn't staged twice.

    Args:
      packages: `DartPackageInfo` records of the packages `files` belong to.
      files: A depset of the packages' Files.
      package_name: The Dart package name to filter on.
      exclude_paths: Optional list of exec path strings to skip.

    Returns:
      `(files, package_root)` — the matching sibling Files and the package's
      package_root. Returns `([], None)` when no matching package is found.
    """
    if exclude_paths == None:
        exclude_paths = []
    package_root = dart_package_root_for_package(packages, package_name)
    if package_root == None:
        return [], None
    prefix = package_lib_prefix(package_root)
    excluded = {p: True for p in exclude_paths}
    seen = {}
    out = []
    for src in files.to_list():
        if src.path in excluded:
            continue
        if src.short_path in seen:
            continue
        if not src.short_path.startswith(prefix):
            continue
        seen[src.short_path] = True
        out.append(src)
    return out, package_root

def add_shim_contract_args(args, ctx, inputs, asset_deps = []):
    """Appends the typed shim-contract flags to `args`.

    Covers `--package`, `--root-language-version`, `--dep` (repeatable —
    `<path>|<asset_path>` form — one per sibling file in `inputs` and entry
    in `asset_deps`), `--part`, `--config`, `--package-config`. Callers add
    `--input`, `--output`, and `--input-asset` themselves (those are specific
    to the calling impl's per-src / per-output loop), and the SDK with
    `codegen_sdk_args()`.

    Args:
      args: The `ctx.actions.args()` object to append flags to.
      ctx: The rule context (reads `package`, `config`, etc.).
      inputs: What the generator reads of its `deps`, as `codegen_deps()`
        returns it.
      asset_deps: List of Files from the rule's `asset_deps` attr (non-Dart
        files the Builder's Resolver must see via `findAssets` /
        `readAsString`). De-duplicated against the siblings by exec path.

    Returns:
      A list of extra action-input Files that callers must include in
      their `ctx.actions.run(inputs=...)`.
    """
    identity = resolve_package_identity(ctx)

    extra_inputs = []
    args.add("--package", identity.package_name)

    language_version = codegen_language_version(ctx, identity)
    args.add("--root-language-version", language_version)
    seen = {}
    synth_pc = inputs.package_config
    package_root = inputs.package_root
    for src in inputs.siblings:
        if src.path in seen:
            continue
        seen[src.path] = True
        args.add("--dep", src, format = "%s|" + format_literal(asset_path_for(src, package_root)))
        extra_inputs.append(src)
    for src in asset_deps:
        if src.path in seen:
            continue
        seen[src.path] = True
        args.add("--dep", src, format = "%s|" + format_literal(asset_path_for(src, package_root)))
        extra_inputs.append(src)

    # Builders read the package's pubspec (`source_gen` its name,
    # `json_serializable` its dependencies). Unless the target passes its own
    # in `asset_deps`, which the shim checks against the target, it is written
    # from the target.
    if not [f for f in asset_deps if asset_path_for(f, package_root) == "pubspec.yaml"]:
        pubspec = ctx.actions.declare_file(ctx.label.name + ".codegen/pubspec.yaml")
        ctx.actions.write(pubspec, derived_pubspec(
            identity.package_name,
            "^%s.0" % language_version,
            inputs.packages,
        ))
        args.add("--dep", pubspec, format = "%s|pubspec.yaml")
        extra_inputs.append(pubspec)
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
    return extra_inputs

def format_literal(text):
    """`text` escaped for an `Args` format string, in which `%` is special."""
    return text.replace("%", "%%")
