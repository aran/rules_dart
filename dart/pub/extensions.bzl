"""Module extension for declaring pub.dev package dependencies."""

load("//dart/ext:registry.bzl", "curated_code_assets")
load("//dart/pub:pub_lock_hub.bzl", "pub_lock_hub")
load("//dart/pub:pub_lock_library.bzl", "index_repo", "library_repo", "pub_lock_index", "pub_lock_library", "source_repo")
load("//dart/pub:pub_lock_package.bzl", "pub_lock_git_package", "pub_lock_package")
load("//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//dart/pub/private:pub_archive.bzl", "check_pub_archive_sha256")
load("//dart/pub/private:pub_git.bzl", "check_pub_git_resolved_ref", "is_relative_git_url")
load("//dart/pub/private:pub_repository.bzl", "pub_package")
load("//dart/pub/private:version.bzl", "semver_gt")

_SPOKE_PREFIX = "dart_pub"

_package = tag_class(
    attrs = {
        "name": attr.string(
            doc = "The pub.dev package name (also used as the repository name).",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive.",
            mandatory = True,
        ),
        "deps": attr.string_list(
            doc = "Repository names of pub packages this package depends on.",
            default = [],
        ),
    },
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
                  "Package versions are reconciled across the union — see " +
                  "`on_version_conflict`.",
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
                  "default.",
            default = [],
        ),
        "on_version_conflict": attr.string(
            doc = "What to do when another lock file provides a higher version of a package. " +
                  "'error' (default) fails the build. 'upgrade' accepts the higher version.",
            default = "error",
            values = ["error", "upgrade"],
        ),
    },
)

def _explicit_packages(ctx, root_lock_names):
    """Decides which `pub.package()` declaration supplies each package it names.

    Bazel's convention: the root module decides. A root declaration wins; so
    does the root's lock over another module's declaration. Two other modules
    that disagree, with the root silent, fail: rules_dart builds one version of
    each package, and which of theirs would be picking for the root.

    Args:
      ctx: The module extension context.
      root_lock_names: Names the root module's locks list, whatever their source.

    Returns:
      `struct(explicit, overridden)`: the winning declaration per name, and the
      names other modules declared that the root's lock supplies instead, each
      with the declaring modules.
    """
    root = {}
    others = {}
    for mod in ctx.modules:
        for pkg in mod.tags.package:
            if mod.is_root:
                root.setdefault(pkg.name, pkg)
            else:
                others.setdefault(pkg.name, []).append(struct(module = mod.name, tag = pkg))

    explicit = dict(root)
    overridden = {}
    for name, decls in others.items():
        if name in root:
            continue
        if name in root_lock_names:
            overridden[name] = [d.module for d in decls]
            continue
        versions = {(d.tag.version, d.tag.sha256): True for d in decls}
        if len(versions) > 1:
            fail(
                ("Package \"%s\" is declared at different versions by modules the root " +
                 "depends on, and the root module states none:\n%s\n" +
                 "rules_dart builds one version of each package. Pin it in the root " +
                 "module, with `pub.package(name = \"%s\", version = ..., sha256 = ...)` " +
                 "or in a lock the root passes to `pub.from_lock()`; the root's choice " +
                 "wins over every other module's.") % (
                    name,
                    "".join([
                        "  - %s (sha256 %s), from module `%s`\n" % (d.tag.version, d.tag.sha256, d.module)
                        for d in decls
                    ]),
                    name,
                ),
            )
        explicit[name] = decls[0].tag
    return struct(explicit = explicit, overridden = overridden)

def _add_git_package(git_registry, name, info, lock_tag):
    """Records a lock's `source: git` entry, failing where it pins nothing or disagrees.

    Every lock that lists a git package must pin the same commit of the same
    repository directory: there is no version order between commits to
    upgrade along.

    Args:
      git_registry: Package name -> what is fetched for it; updated.
      name: The package name.
      info: The lock entry.
      lock_tag: The `from_lock` tag whose lock lists it.
    """
    desc = info.get("description", {})
    version = info.get("version", "")
    url = desc.get("url", "")
    if not url:
        fail("The git package \"%s\" %s (in %s) has no `description.url`. Run `dart pub get` to rewrite the lock." % (name, version, lock_tag.lock))
    check_pub_git_resolved_ref(name, version, desc.get("resolved-ref", ""), str(lock_tag.lock))
    relative = is_relative_git_url(url)
    pkg = struct(
        version = version,
        url = url,
        resolved_ref = desc["resolved-ref"],
        path = desc.get("path", "."),
        # A relative url is resolved against the lock's directory, so the
        # lock is part of what it names.
        lock = lock_tag.lock if relative else None,
        lock_label = str(lock_tag.lock),
    )
    first = git_registry.setdefault(name, pkg)
    if (first.url, first.lock, first.resolved_ref, first.path) != (pkg.url, pkg.lock, pkg.resolved_ref, pkg.path):
        fail(
            ("Git package \"%s\" is locked differently across lock files:\n" +
             "  - %s at %s, path %s (from %s)\n" +
             "  - %s at %s, path %s (from %s)\n" +
             "rules_dart builds one copy of each package. Make the pubspecs ask for the " +
             "same commit and run `dart pub get` in each workspace.") % (
                name,
                first.url,
                first.resolved_ref,
                first.path,
                first.lock_label,
                pkg.url,
                pkg.resolved_ref,
                pkg.path,
                pkg.lock_label,
            ),
        )

def _pub_impl(ctx):
    # Packages the user has declared hook-irrelevant, unioned across every
    # from_lock call — a package is one repo regardless of how many locks
    # mention it, so the flag cannot be per-lock.
    ignore_hooks = {}
    for mod in ctx.modules:
        for lock_tag in mod.tags.from_lock:
            for pkg_name in lock_tag.ignore_hooks:
                ignore_hooks[pkg_name] = True

    # Repos the root module names, mapped to whether every naming is a
    # `dev_dependency = True` usage: Bazel checks the root's `use_repo` calls
    # against that split, and fails a dev-only root that reports non-dev repos.
    root_repos = {}

    # Every lock, parsed once, in module order.
    locks = []
    root_lock_names = {}
    for mod in ctx.modules:
        for lock_tag in mod.tags.from_lock:
            lock_pkgs = parse_pubspec_lock(ctx.read(lock_tag.lock))
            locks.append(struct(module = mod, tag = lock_tag, packages = lock_pkgs))
            if mod.is_root:
                for name in lock_pkgs:
                    root_lock_names[name] = True

    # Individual package declarations take priority over the locks, and the
    # root module's statements over every other module's.
    explicit_packages = _explicit_packages(ctx, root_lock_names)
    explicit = explicit_packages.explicit
    for mod in ctx.modules:
        if mod.is_root:
            for pkg in mod.tags.package:
                root_repos[pkg.name] = root_repos.get(pkg.name, True) and ctx.is_dev_dependency(pkg)

    for name, pkg in explicit.items():
        check_pub_archive_sha256(name, pkg.version, pkg.sha256, "pub.package()")
        pub_package(
            name = name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            deps = pkg.deps,
        )

    # Collect all packages from all lock files into a unified registry.
    # registry[pkg_name] = {url, entries: [{version, sha256, hub_name, lock_label, on_version_conflict}]}
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

    # Packages a lock lists that no repository is fetched for (path and SDK
    # sources), with how the first such lock lists each.
    non_hosted = {}

    for lock in locks:
        mod = lock.module
        lock_tag = lock.tag
        hub_name = lock_tag.name
        if mod.is_root:
            root_repos[hub_name] = root_repos.get(hub_name, True) and ctx.is_dev_dependency(lock_tag)

        hub_packages.setdefault(hub_name, {})

        # Hosted and git packages are fetched. Collect every other package
        # and report once per lock file — Flutter locks routinely list many
        # sdk-source packages, so a per-package print would drown the useful
        # signal.
        skipped_by_source = {}

        for name, info in lock.packages.items():
            # A package declared with `pub.package()` is that repository,
            # however the lock lists it.
            if name in explicit:
                hub_packages[hub_name][name] = True
                continue

            source = info.get("source", "unknown")
            if source == "git":
                hub_packages[hub_name][name] = True
                _add_git_package(git_registry, name, info, lock_tag)
                continue
            if source != "hosted":
                skipped_by_source.setdefault(source, []).append(name)
                non_hosted.setdefault(name, "a `%s` package in %s" % (source, lock_tag.lock))
                continue

            hub_packages[hub_name][name] = True

            desc = info.get("description", {})
            url = desc.get("url", "https://pub.dev")
            version = info.get("version", "")
            sha256 = desc.get("sha256", "")
            check_pub_archive_sha256(name, version, sha256, str(lock_tag.lock))
            entry = struct(
                version = version,
                sha256 = sha256,
                hub_name = hub_name,
                lock_label = str(lock_tag.lock),
                on_version_conflict = lock_tag.on_version_conflict,
            )

            if name not in registry:
                registry[name] = struct(url = url, entries = [entry])
            else:
                existing = registry[name]
                if existing.url != url:
                    fail(
                        "Package \"%s\" has conflicting registry URLs:\n" % name +
                        "  - %s (from \"%s\")\n" % (existing.url, existing.entries[0].hub_name) +
                        "  - %s (from \"%s\")\n" % (url, hub_name),
                    )
                registry[name] = struct(url = existing.url, entries = existing.entries + [entry])

        if skipped_by_source:
            details = []
            for source in sorted(skipped_by_source.keys()):
                if source == "sdk":
                    remedy = "provided by the Dart/Flutter SDK, not fetched by pub"
                else:
                    remedy = "declare via pub.package() or a local dart_library"
                details.append("  - %s (%s): %s" % (
                    source,
                    remedy,
                    ", ".join(sorted(skipped_by_source[source])),
                ))

            # buildifier: disable=print
            print(
                ("pub.from_lock(%s): %s lists non-hosted packages; no repository " +
                 "is created for them, so `package:` imports of these packages " +
                 "will fail to resolve unless they are provided another way:\n%s") % (
                    hub_name,
                    lock_tag.lock,
                    "\n".join(details),
                ),
            )

    for name, git_pkg in git_registry.items():
        if name in registry:
            fail(
                ("Package \"%s\" is a git package in %s and a hosted package in %s. " +
                 "rules_dart builds one copy of each package; make the locks agree, " +
                 "or declare it with `pub.package()` in the root module.") % (
                    name,
                    git_pkg.lock_label,
                    registry[name].entries[0].lock_label,
                ),
            )

    # Resolve each package to a single version
    resolved = {}  # pkg_name -> {version, sha256, url}
    for name, pkg in registry.items():
        # One archive per version: locks that pin it to different digests
        # cannot all describe what is fetched, whichever is listed first.
        digests = {}
        for e in pkg.entries:
            first = digests.setdefault(e.version, e)
            if first.sha256 != e.sha256:
                fail(
                    "Package \"%s\" %s has conflicting sha256 digests across lock files:\n" % (name, e.version) +
                    "  - %s (from \"%s\", %s)\n" % (first.sha256, first.hub_name, first.lock_label) +
                    "  - %s (from \"%s\", %s)\n" % (e.sha256, e.hub_name, e.lock_label) +
                    "\nAt most one of them describes the archive the registry serves. " +
                    "`dart pub get` in each workspace checks its lock's digests against the " +
                    "registry and reports a wrong one.",
                )

        if len(pkg.entries) == 1:
            e = pkg.entries[0]
            resolved[name] = struct(version = e.version, sha256 = e.sha256, url = pkg.url)
            continue

        # Find the highest version
        best = pkg.entries[0]
        for e in pkg.entries[1:]:
            if semver_gt(e.version, best.version):
                best = e

        # Check that all lower-version entries allow upgrading
        for e in pkg.entries:
            if e.version != best.version and e.on_version_conflict == "error":
                fail(
                    "Package \"%s\" has conflicting versions across lock files:\n" % name +
                    "".join([
                        "  - %s (from \"%s\", %s)\n" % (entry.version, entry.hub_name, entry.lock_label)
                        for entry in pkg.entries
                    ]) +
                    "\nThe pubspec.lock files pinned different versions of a shared transitive\n" +
                    "package. `dart pub get` preserves existing locked versions, so it won't\n" +
                    "bring them back into sync. To resolve:\n" +
                    "\n" +
                    "  1. (Preferred) Run `dart pub upgrade` in the workspace with the lower\n" +
                    "     version. This re-resolves transitive packages within their constraints,\n" +
                    "     pulling the shared dependency forward to match.\n" +
                    "\n" +
                    "  2. If constraints prevent the upgrade, set on_version_conflict = \"upgrade\"\n" +
                    "     on the from_lock() call with the lower version, allowing it to accept\n" +
                    "     the higher.\n" +
                    "\n" +
                    "  3. Or pin centrally with an explicit declaration:\n" +
                    "       pub.package(name = \"%s\", version = \"%s\", sha256 = \"%s\", deps = [...])\n" % (name, best.version, best.sha256) +
                    "       # You may need to manually add deps for this package.\n" +
                    "\nrules_dart does not support multiple versions of a package, even across lock files.",
                )

        resolved[name] = struct(version = best.version, sha256 = best.sha256, url = pkg.url)

    # Create a source repository and a library repository per package.
    explicit_names = sorted(explicit.keys())
    fetched = {name: pkg.version for name, pkg in resolved.items()}
    fetched.update({name: pkg.version for name, pkg in git_registry.items()})
    unsupplied = {
        name: why
        for name, why in non_hosted.items()
        if name not in fetched
    }
    pub_lock_index(
        name = index_repo(_SPOKE_PREFIX),
        versions = fetched,
        explicit_packages = explicit_names,
        unsupplied = unsupplied,
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

    def library_label(name):
        if name in explicit:
            return "@{name}//:{name}".format(name = name)
        return "@{repo}//:{name}".format(repo = library_repo(_SPOKE_PREFIX, name), name = name)

    # A package another module declared, which the root's lock supplies
    # instead, keeps its repository name for that module's `use_repo`.
    for name, modules in explicit_packages.overridden.items():
        if name not in fetched:
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

    # Create per-from_lock hub repos
    for hub_name, packages in hub_packages.items():
        pub_lock_hub(
            name = hub_name,
            packages = {name: library_label(name) for name in packages},
        )

    return ctx.extension_metadata(
        root_module_direct_deps = [name for name, dev in root_repos.items() if not dev],
        root_module_direct_dev_deps = [name for name, dev in root_repos.items() if dev],
    )

pub = module_extension(
    implementation = _pub_impl,
    tag_classes = {
        "package": _package,
        "from_lock": _from_lock,
    },
    doc = "Declares pub.dev package dependencies for download and use as dart_library targets.",
)
