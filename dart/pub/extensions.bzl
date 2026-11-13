"""Module extension for declaring pub.dev package dependencies."""

load("//dart/ext:registry.bzl", "curated_code_assets", "curated_cycles")
load("//dart/pub:pub_graph.bzl", "cycle_declaration", "cycle_declarations_error")
load("//dart/pub:pub_lock_package.bzl", "pub_lock_git_package", "pub_lock_package", "pub_lock_path_package", "pub_lock_resolved_pubspec")
load("//dart/pub:pub_versions.bzl", "CHECK_LEVELS", "pub_version_request", "select_pub_version")
load("//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//dart/pub/private:pub_archive.bzl", "pub_archive_sha256_error")
load("//dart/pub/private:pub_lock_checks.bzl", "git_disagreement_error", "git_lock_package", "lock_mapping_error", "path_packages", "pub_command", "resolved_packages", "resolved_pubspecs", "source_disagreement_errors")
load("//dart/pub/private:pub_lock_hub.bzl", "pub_lock_hub")
load("//dart/pub/private:pub_lock_library.bzl", "index_repo", "library_repo", "pub_lock_ignored", "pub_lock_index", "pub_lock_library", "pub_lock_resolved", "source_repo")
load("//dart/pub/private:pub_settings.bzl", "root_only_settings")

_SPOKE_PREFIX = "dart_pub"

_package = tag_class(
    attrs = {
        "name": attr.string(
            doc = "The pub.dev package name (also used as the repository name).",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The least version this module accepts. Every `pub.package()` and every " +
                  "lock entry of the package in the build is a request, and the highest " +
                  "is built (see `pub.settings`).",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive.",
            mandatory = True,
        ),
        "ignore_hook": attr.bool(
            doc = "The package's `hook/build.dart` is knowingly irrelevant to this build " +
                  "(its native code is never reached): suppresses the unreplaced-hook error " +
                  "for it, as `pub.from_lock(ignore_hooks = [...])` does for a lock's " +
                  "packages. A declaration you make deliberately; never a default. Only the " +
                  "root module may set it: whether a hook matters depends on the programs " +
                  "the build makes, which are the root's.",
            default = False,
        ),
    },
    doc = "A pub.dev package, built with the dependencies its pubspec states: each " +
          "must be supplied by another `pub.package()` or a lock, or the fetch fails.",
)

_cycle = tag_class(
    attrs = {
        "packages": attr.string_list(
            doc = "Every package of the cycle. Each must be one this extension fetches " +
                  "(from a lock or a `pub.package()`), and none may be in another " +
                  "`pub.cycle()` of the module.",
            mandatory = True,
        ),
    },
    doc = "Pub packages that depend on each other in a cycle, built as one library. " +
          "Pub allows a cycle and Bazel does not, so a cycle builds only where it is " +
          "declared; an undeclared one fails when it is planned, giving the declaration " +
          "to write. Like versions, cycles are build-wide, and the root module decides: " +
          "its declarations must each be exactly a cycle at the versions the build " +
          "fetches, or the build fails (so a declaration cannot outlive its cycle). " +
          "Another module's declarations, and rules_dart's curated ones " +
          "(`curated_cycles()` in `@rules_dart//dart/ext:registry.bzl`), apply where " +
          "they are exactly a cycle and are inert where they are not. Declarations that " +
          "name the same packages agree; ones that share only some of them cannot both " +
          "be exactly a cycle, and the root's is checked, so at most one applies.",
)

_from_lock = tag_class(
    attrs = {
        "name": attr.string(
            doc = "Repository name for the resolved packages. The name is global to the " +
                  "extension, not scoped to the declaring module: every `from_lock` that " +
                  "states it — in any module in the build — contributes to one hub holding " +
                  "the union of those locks, and each package is aliased once. That is what " +
                  "makes two modules that both call their hub the obvious thing work when a " +
                  "third depends on both. It also means a module can reach a package only " +
                  "another module's lock names, which resolves today and breaks the day that " +
                  "module leaves the build, so state in your own lock everything you import. " +
                  "Versions are chosen build-wide, the highest request winning — see " +
                  "`pub.settings`.",
            mandatory = True,
        ),
        "lock": attr.label(
            doc = "The pubspec.lock file to parse.",
            mandatory = True,
            allow_single_file = True,
        ),
        "ignore_hooks": attr.string_list(
            doc = "Pub package names whose `hook/build.dart` is knowingly irrelevant to this " +
                  "build (its native code is never reached). Suppresses the unreplaced-hook " +
                  "error for them. This is a declaration you make deliberately; it is never a " +
                  "default. Only the root module may set it: whether a hook matters depends on " +
                  "the programs the build makes, which are the root's.",
            default = [],
        ),
        "resolve": attr.string_keyed_label_dict(
            doc = "Locked packages served by a target of yours instead of what the lock " +
                  "describes, each package name with the target that builds that package " +
                  "(its `DartPackageInfo` must carry that name, which is checked when the " +
                  "target is analyzed). Every `path` package in the lock must be named in " +
                  "exactly one of `resolve`, `build_from_pubspec` or `ignored`; a " +
                  "`hosted`, `git` or `sdk` package may be listed here. A listed package is that target " +
                  "for the whole build: its hub label aliases it, and every locked package " +
                  "that depends on it depends on the target. The lock's version of it is not " +
                  "checked. A name the lock does not list is an error, as is a package two " +
                  "`from_lock` calls map to different targets.",
            default = {},
        ),
        "build_from_pubspec": attr.string_list(
            doc = "`path` packages of the lock to build from their directory, as a hosted " +
                  "package is built from its archive: the lock's path, resolved against the " +
                  "lock's directory, holds the package, and its `pubspec.yaml`, `lib/`, " +
                  "`hook/` and license file are served from there. For a package with no " +
                  "Bazel build of its own; one with a `BUILD` file is mapped with `resolve`. " +
                  "Two locks building one package must name the same directory.",
            default = [],
        ),
        "ignored": attr.string_dict(
            doc = "`path` packages of the lock that nothing in the build may use, each with " +
                  "the reason, such as a package only an editor or a pub-side tool reads. " +
                  "Its hub label exists, and anything that depends on it fails at analysis " +
                  "with that reason.",
            default = {},
        ),
    },
    doc = "The packages a `pubspec.lock` names, each built as a library with the " +
          "dependencies its pubspec states and aliased in the hub `name`. `hosted` and " +
          "`git` packages are fetched; every `path` package is named in `resolve`, " +
          "`build_from_pubspec` or `ignored`; an `sdk` package is skipped unless `resolve` " +
          "maps it.",
)

_settings = tag_class(
    attrs = {
        "check_direct_dependencies": attr.string(
            doc = "What to do when one of the root module's own requests (a " +
                  "`pub.package()` or a hosted lock entry) is raised by a higher request " +
                  "elsewhere in the build: `warning` (the default) prints the package, both " +
                  "versions, who raised it and how to raise the root's, `error` fails the " +
                  "build with that message, and `off` says nothing. Raising another module's " +
                  "request is what a minimum means and is never reported. Bazel's " +
                  "`--check_direct_dependencies` does the same for `bazel_dep`.",
            default = "warning",
            values = CHECK_LEVELS,
        ),
    },
    doc = "How the extension reports the build's version choices. Every statement of a " +
          "hosted package's version, each module's `pub.package()` and each lock entry " +
          "alike, is a request, and the highest is built, as Bazel's minimal version " +
          "selection does for modules. Two requests of one version must pin one digest. " +
          "Only the root module may use this tag, at most once.",
)

def _where_lock(module, lock):
    where = "the lock `//%s:%s`" % (lock.package, lock.name)
    if not module.is_root:
        where += " in module `%s`" % module.name
    return where

def _where_declaration(module):
    if module.is_root:
        return "`pub.package()` in the root module"
    return "`pub.package()` in module `%s`" % module.name

def _root_unversioned(locks):
    """The packages the root's locks list from a source with no version order.

    Such a package (git, sdk, path) is what the root's lock says for the whole
    build, over every other module's statement of it, lock entry or
    `pub.package()`, as a root `git_override` is over a `bazel_dep`: there is
    no order to pick the highest by.

    Args:
      locks: Every lock, as `_pub_impl` parses them.

    Returns:
      Package name -> its `source` in the root's lock.
    """
    root_unversioned = {}
    for lock in locks:
        if lock.module.is_root:
            for name, info in lock.packages.items():
                if info.get("source") != "hosted":
                    root_unversioned[name] = info.get("source")
    return root_unversioned

def _declarations(ctx, root_unversioned):
    """Collects every module's `pub.package()` declarations that request a version.

    A package the root's lock lists from a source with no version order, and
    the root does not declare, is what that lock says: another module's
    declaration of it then names the root's choice.

    Args:
      ctx: The module extension context.
      root_unversioned: `_root_unversioned`'s result.

    Returns:
      `struct(declared, overridden)`: package name -> the declarations that
      request it, each `struct(module, tag)`, in module order; and package
      name -> the modules whose declarations the root's lock supplies instead.
    """
    declarations = {}
    for mod in ctx.modules:
        for pkg in mod.tags.package:
            declarations.setdefault(pkg.name, []).append(struct(module = mod, tag = pkg))
    declared = {}
    overridden = {}
    for name, decls in declarations.items():
        if name in root_unversioned and not any([d.module.is_root for d in decls]):
            overridden[name] = [d.module.name for d in decls]
        else:
            declared[name] = decls
    return struct(declared = declared, overridden = overridden)

def _select_versions(name, decls, entries, url, check):
    """Picks a hosted package's version from its declarations and lock entries.

    Args:
      name: The package.
      decls: Its `pub.package()` declarations, as `_declarations` gives them.
      entries: Its hosted lock entries.
      url: The registry its lock entries name, or pub.dev.
      check: The root's `check_direct_dependencies`.

    Returns:
      `struct(version, sha256, url, declared, warnings, error)`: the winner,
      whether a declaration states it (its repository is then named for the
      package), and the messages.
    """
    requests = [
        pub_version_request(
            version = d.tag.version,
            sha256 = d.tag.sha256,
            url = "https://pub.dev",
            is_root = d.module.is_root,
            where = _where_declaration(d.module),
        )
        for d in decls
    ] + [
        pub_version_request(
            version = e.version,
            sha256 = e.sha256,
            url = url,
            is_root = e.is_root,
            where = e.where,
            upgrade = pub_command("upgrade", e.lock_file, [name]),
            refresh = pub_command("get", e.lock_file),
        )
        for e in entries
    ]
    selection = select_pub_version(name, requests, check)
    if selection.error:
        return struct(error = selection.error, warnings = [])
    winner = selection.request
    warnings = [selection.warning] if selection.warning else []
    return struct(
        version = winner.version,
        sha256 = winner.sha256,
        url = winner.url,
        declared = any([d.tag.version == winner.version for d in decls]),
        warnings = warnings,
        error = None,
    )

def _cycles(ctx, fetched, resolved_targets, ignored):
    """Collects the `pub.cycle()` declarations every library repository plans against.

    Fails where a module's declarations are malformed, or where the root's
    name a package this extension does not fetch: neither can be a cycle,
    whatever the versions.

    Args:
      ctx: The module extension context.
      fetched: Every package with a source repository, with its version.
      resolved_targets: The packages `resolve` maps to a workspace target.
      ignored: The `path` packages `ignored` names.

    Returns:
      `struct(declared, advisory)`: the root module's declarations, each sorted,
      and every other one (other modules', and rules_dart's curated ones) whose
      packages are all fetched, each sorted and stated once.
    """
    declared = []
    advisory = {}
    for mod in ctx.modules:
        groups = [sorted(tag.packages) for tag in mod.tags.cycle]
        where = "the root module" if mod.is_root else "module `%s`" % mod.name
        error = cycle_declarations_error(groups, where, "pub.cycle")
        if error:
            fail(error)
        if not mod.is_root:
            for group in groups:
                advisory[" ".join(group)] = group
            continue
        for group in groups:
            problems = []
            for name in group:
                if name in fetched:
                    continue
                if name in resolved_targets:
                    why = "maps to %s with `resolve`, so a target of yours builds it" % resolved_targets[name].target
                elif name in ignored:
                    why = "names in `ignored`"
                else:
                    why = "neither lists in a lock as a package it fetches nor declares with `pub.package()`"
                problems.append("  - `%s`, which the build %s" % (name, why))
            if problems:
                fail(("%s, in the root module, names packages this build does not fetch, so " +
                      "they are in no cycle it builds:\n%s\nRemove each from the declaration, or remove the declaration.") % (
                    cycle_declaration(group, "pub.cycle"),
                    "\n".join(problems),
                ))
            declared.append(group)
    for group in curated_cycles():
        advisory[" ".join(group)] = group
    return struct(
        declared = declared,
        advisory = [
            advisory[key]
            for key in sorted(advisory)
            if all([name in fetched for name in advisory[key]])
        ],
    )

def _pub_impl(ctx):
    # The root's settings, and the packages whose hooks it declared
    # irrelevant: a package is one repository however many tags name it, so
    # the flag is per package, never per tag.
    settings = root_only_settings(ctx.modules)
    if settings.error:
        fail(settings.error)
    ignore_hooks = settings.ignore_hooks

    # Repos the root module names, mapped to whether every naming is a
    # `dev_dependency = True` usage: Bazel checks the root's `use_repo` calls
    # against that split, and fails a dev-only root that reports non-dev repos.
    root_repos = {}

    # Every lock, parsed once, in module order.
    locks = []
    for mod in ctx.modules:
        for lock_tag in mod.tags.from_lock:
            lock_pkgs = parse_pubspec_lock(ctx.read(lock_tag.lock), lock_tag.lock)
            locks.append(struct(module = mod, tag = lock_tag, packages = lock_pkgs))

    # Every module's `pub.package()` requests, and the ones the root's lock
    # supplies instead.
    root_unversioned = _root_unversioned(locks)
    declarations = _declarations(ctx, root_unversioned)
    declared = declarations.declared
    for mod in ctx.modules:
        if mod.is_root:
            for pkg in mod.tags.package:
                root_repos[pkg.name] = root_repos.get(pkg.name, True) and ctx.is_dev_dependency(pkg)

    # Every refusal of a phase is collected and reported in one failure. A
    # phase ends where the next needs what the refusals reject.
    errors = []

    # A declaration's digest needs nothing else read, so it is reported with
    # whichever phase fails first. A refused one requests nothing.
    pinned = {}
    for name, decls in declared.items():
        for d in decls:
            error = pub_archive_sha256_error(d.tag.name, d.tag.version, d.tag.sha256, "pub.package()")
            if error:
                errors.append(error)
            else:
                pinned.setdefault(name, []).append(d)

    # Each lock's own `resolve`, `build_from_pubspec` and `ignored`. Until
    # they are right, what serves a lock's packages is unknown.
    mapping_errors = [e for e in [lock_mapping_error(lock) for lock in locks] if e]
    if mapping_errors:
        fail("\n\n".join(errors + mapping_errors))

    # Packages a workspace target serves, by `resolve`, and the `path`
    # packages built from their pubspec or ignored. A package they disagree
    # on is still served by one of them, so nothing below fetches it.
    mapped = resolved_packages(locks, declared)
    resolved_targets = mapped.targets
    paths = path_packages(locks, declared, resolved_targets)

    # The mapped packages whose pubspec planning reads, to find a cycle
    # between one and pub packages, which no declaration can build.
    readable = resolved_pubspecs(locks, resolved_targets)
    errors.extend(mapped.errors + paths.errors)

    # Every hosted lock entry, per package: each is a version request.
    registry = {}

    # Which packages belong to each hub, as a set per hub (for per-hub alias
    # creation). A set, not a list, because a hub name is shared by every
    # `from_lock` that states it — including ones in *different modules*, which
    # cannot coordinate their naming and routinely land on the same obvious
    # name. Such a hub holds the union of those locks, and a package both locks
    # name must still be aliased once: two `alias` rules of one name make the
    # generated BUILD file fail to load, which Bazel reports as the *next*
    # package being undeclared, naming neither the duplicate nor the two locks.
    hub_packages = {}

    # Git packages, each with the one commit every lock that lists it pins.
    git_registry = {}

    # Packages a lock lists that no repository is fetched for (SDK sources and
    # those pub does not know, unless mapped), with how the first such lock
    # lists each.
    non_hosted = {}

    for lock in locks:
        mod = lock.module
        lock_tag = lock.tag
        hub_name = lock_tag.name
        if mod.is_root:
            root_repos[hub_name] = root_repos.get(hub_name, True) and ctx.is_dev_dependency(lock_tag)

        hub_packages.setdefault(hub_name, {})

        # Hosted and git packages are fetched, and path packages are mapped.
        # sdk packages are reported once per lock file: Flutter locks list
        # many, so a per-package print would drown the useful signal.
        skipped_sdk = []

        for name, info in lock.packages.items():
            # One `resolve` maps is that target, however the lock lists it.
            if name in resolved_targets or name in paths.built or name in paths.ignored:
                hub_packages[hub_name][name] = True
                continue

            # A `pub.package()` supplies a package the lock lists from a source
            # with no version to compare (git, sdk); a hosted entry is one more
            # request for it.
            source = info["source"]
            if name in declared and source != "hosted":
                hub_packages[hub_name][name] = True
                continue

            # Another module's entry for a package the root's lock lists from
            # a source with no version order is the root's entry: a git
            # package is the root's commit, and an sdk one is not fetched.
            if not mod.is_root and name in root_unversioned and name not in declared:
                if root_unversioned[name] == "git":
                    hub_packages[hub_name][name] = True
                continue
            if source == "git":
                hub_packages[hub_name][name] = True
                git = git_lock_package(name, info, lock_tag)
                errors.extend(git.errors)
                if git.package:
                    first = git_registry.setdefault(name, git.package)
                    disagreement = git_disagreement_error(name, first, git.package)
                    if disagreement:
                        errors.append(disagreement)
                continue
            if source != "hosted":
                if source == "sdk":
                    skipped_sdk.append(name)
                non_hosted.setdefault(name, "a `%s` package in %s" % (source, lock_tag.lock))
                continue

            hub_packages[hub_name][name] = True

            desc = info.get("description", {})
            url = desc.get("url", "https://pub.dev")
            version = info.get("version", "")
            sha256 = desc.get("sha256", "")
            error = pub_archive_sha256_error(
                name,
                version,
                sha256,
                str(lock_tag.lock),
                rewrite = pub_command("get", lock_tag.lock),
            )
            if error:
                # An entry that pins nothing requests nothing, so it is in no
                # disagreement over digests.
                errors.append(error)
                continue
            registry.setdefault(name, []).append(struct(
                version = version,
                sha256 = sha256,
                url = url,
                is_root = mod.is_root,
                where = _where_lock(mod, lock_tag.lock),
                lock_label = str(lock_tag.lock),
                lock_file = lock_tag.lock,
            ))

        if skipped_sdk:
            # buildifier: disable=print
            print(
                ("pub.from_lock(%s): %s lists packages from the Dart/Flutter SDK, which pub " +
                 "does not fetch; no repository is created for them, so `package:` imports " +
                 "of these packages will fail to resolve unless they are provided another " +
                 "way (`resolve`):\n  %s") % (
                    hub_name,
                    lock_tag.lock,
                    ", ".join(sorted(skipped_sdk)),
                ),
            )

    errors.extend(source_disagreement_errors(paths.built, git_registry, registry))

    # One version per hosted package: the highest request, a `pub.package()`
    # in any module or a lock entry, wins.
    explicit = {}  # name -> the winning declaration's version and digest
    resolved = {}  # name -> the winning lock entry's version, digest and registry
    for name in sorted(declared.keys() + [n for n in registry if n not in declared]):
        entries = registry.get(name, [])
        if not entries and name not in pinned:
            continue
        selection = _select_versions(
            name,
            pinned.get(name, []),
            entries,
            entries[0].url if entries else "https://pub.dev",
            settings.check,
        )
        if selection.error:
            errors.append(selection.error)
            continue
        for warning in selection.warnings:
            # buildifier: disable=print
            print(warning)
        pkg = struct(version = selection.version, sha256 = selection.sha256, url = selection.url)
        if selection.declared:
            explicit[name] = pkg
        else:
            resolved[name] = pkg
    if errors:
        fail("\n\n".join(errors))

    # A package declared with `pub.package()` whose winning request is a
    # declaration is a source and a library repository, as a locked one is,
    # so it is planned with the others and can be in a cycle with them. Its
    # library repository is named for it.
    for name, pkg in explicit.items():
        pub_lock_package(
            name = source_repo(_SPOKE_PREFIX, name),
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            base_url = pkg.url,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
        )
        pub_lock_library(
            name = name,
            package_name = name,
            spoke_prefix = _SPOKE_PREFIX,
        )

    # Create a source repository and a library repository per package.
    explicit_names = sorted(explicit.keys())
    fetched = {name: pkg.version for name, pkg in resolved.items()}
    fetched.update({name: pkg.version for name, pkg in git_registry.items()})
    fetched.update({name: pkg.version for name, pkg in paths.built.items()})
    fetched.update({name: pkg.version for name, pkg in explicit.items()})
    cycles = _cycles(ctx, fetched, resolved_targets, paths.ignored)
    unsupplied = {
        name: why
        for name, why in non_hosted.items()
        if name not in fetched and name not in resolved_targets and name not in paths.ignored
    }
    pub_lock_index(
        name = index_repo(_SPOKE_PREFIX),
        versions = fetched,
        explicit_packages = explicit_names,
        # An ignored package's library repository is where its dependents
        # look, as for a mapped one.
        resolved_packages = sorted(resolved_targets.keys() + paths.ignored.keys()),
        unsupplied = unsupplied,
        cycles = [" ".join(c) for c in cycles.declared],
        advisory_cycles = [" ".join(c) for c in cycles.advisory],
        served = {name: str(pkg.target) for name, pkg in readable.items()},
    )
    for name, pkg in git_registry.items():
        pub_lock_git_package(
            name = source_repo(_SPOKE_PREFIX, name),
            package_name = name,
            version = pkg.version,
            url = pkg.url,
            resolved_ref = pkg.resolved_ref,
            path = pkg.path,
            lock = pkg.lock,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
        )
        pub_lock_library(
            name = library_repo(_SPOKE_PREFIX, name),
            package_name = name,
            spoke_prefix = _SPOKE_PREFIX,
        )
    for name, pkg in resolved.items():
        pub_lock_package(
            name = source_repo(_SPOKE_PREFIX, name),
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            base_url = pkg.url,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
        )
        pub_lock_library(
            name = library_repo(_SPOKE_PREFIX, name),
            package_name = name,
            spoke_prefix = _SPOKE_PREFIX,
        )

    for name, pkg in paths.built.items():
        pub_lock_path_package(
            name = source_repo(_SPOKE_PREFIX, name),
            package_name = name,
            version = pkg.version,
            lock = pkg.lock,
            path = pkg.path,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
        )
        pub_lock_library(
            name = library_repo(_SPOKE_PREFIX, name),
            package_name = name,
            spoke_prefix = _SPOKE_PREFIX,
        )

    for name, pkg in paths.ignored.items():
        pub_lock_ignored(
            name = library_repo(_SPOKE_PREFIX, name),
            package_name = name,
            lock = pkg.lock_label,
            reason = pkg.reason,
        )

    for name, pkg in readable.items():
        pub_lock_resolved_pubspec(
            name = source_repo(_SPOKE_PREFIX, name),
            package_name = name,
            version = pkg.version,
            lock = pkg.lock,
            path = pkg.path,
        )
    for name, resolved in resolved_targets.items():
        pub_lock_resolved(
            name = library_repo(_SPOKE_PREFIX, name),
            package_name = name,
            actual = str(resolved.target),
        )

    def library_label(name):
        if name in explicit:
            return "@{name}//:{name}".format(name = name)
        return "@{repo}//:{name}".format(repo = library_repo(_SPOKE_PREFIX, name), name = name)

    # A package the root's lock supplies over another module's declaration
    # keeps its repository name for that module's `use_repo`.
    for name, modules in declarations.overridden.items():
        if name not in fetched and name not in resolved_targets:
            fail(
                ("Package \"%s\" is declared with `pub.package()` by %s, and the root " +
                 "module's lock lists it as %s, which `pub.from_lock()` does not fetch. " +
                 "The root's choice wins, so the root must supply it: declare it with " +
                 "`pub.package()` in the root module.") % (
                    name,
                    ", ".join(["module `%s`" % m for m in modules]),
                    unsupplied.get(name, "a package no lock supplies"),
                ),
            )
        pub_lock_hub(
            name = name,
            packages = {name: library_label(name)},
        )

    # So does a declared package whose winning request is a lock entry.
    for name in declared:
        if name not in explicit:
            pub_lock_hub(
                name = name,
                packages = {name: library_label(name)},
            )

    # Create per-from_lock hub repos
    for hub_name, packages in hub_packages.items():
        pub_lock_hub(
            name = hub_name,
            packages = {name: library_label(name) for name in packages},
        )

    # The repositories are fixed by the tags and the locks read above: a
    # hosted package without a sha256 or a git package without a commit id
    # fails, so nothing depends on what a server holds on the day.
    return ctx.extension_metadata(
        root_module_direct_deps = [name for name, dev in root_repos.items() if not dev],
        root_module_direct_dev_deps = [name for name, dev in root_repos.items() if dev],
        reproducible = True,
    )

pub = module_extension(
    implementation = _pub_impl,
    tag_classes = {
        "package": _package,
        "from_lock": _from_lock,
        "cycle": _cycle,
        "settings": _settings,
    },
    doc = "Declares pub package dependencies (hosted, git and path) for download and use as dart_library targets.",
)
