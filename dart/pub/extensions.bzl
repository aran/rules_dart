"""Module extension for declaring pub.dev package dependencies."""

load("//dart/ext:registry.bzl", "curated_code_assets")
load("//dart/pub:pub_lock_hub.bzl", "pub_lock_hub")
load("//dart/pub:pub_lock_package.bzl", "pub_lock_package")
load("//dart/pub:yaml_parser.bzl", "lock_package_error", "parse_pubspec_lock")
load("//dart/pub/private:pub_repository.bzl", "pub_package", "pub_package_sha256_error")
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

def _pub_impl(ctx):
    # Packages the user has declared hook-irrelevant, unioned across every
    # from_lock call — a package is one repo regardless of how many locks
    # mention it, so the flag cannot be per-lock.
    ignore_hooks = {}
    for mod in ctx.modules:
        for lock_tag in mod.tags.from_lock:
            for pkg_name in lock_tag.ignore_hooks:
                ignore_hooks[pkg_name] = True

    # Handle individual package declarations — these take priority
    explicit = {}

    # Repos the root module names, mapped to whether every naming is a
    # `dev_dependency = True` usage: Bazel checks the root's `use_repo` calls
    # against that split, and fails a dev-only root that reports non-dev repos.
    root_repos = {}
    for mod in ctx.modules:
        for pkg in mod.tags.package:
            if pkg.name not in explicit:
                explicit[pkg.name] = pkg
            if mod.is_root:
                root_repos[pkg.name] = root_repos.get(pkg.name, True) and ctx.is_dev_dependency(pkg)

    for name, pkg in explicit.items():
        err = pub_package_sha256_error(name, pkg.version, pkg.sha256)
        if err:
            fail(err)
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

    for mod in ctx.modules:
        for lock_tag in mod.tags.from_lock:
            hub_name = lock_tag.name
            if mod.is_root:
                root_repos[hub_name] = root_repos.get(hub_name, True) and ctx.is_dev_dependency(lock_tag)
            lock_content = ctx.read(lock_tag.lock)
            lock_pkgs = parse_pubspec_lock(lock_content)

            hub_packages.setdefault(hub_name, {})

            # Only hosted packages can be fetched from a pub registry. Collect
            # every non-hosted package and report once per lock file — Flutter
            # locks routinely list many sdk-source packages, so a per-package
            # print would drown the useful signal.
            skipped_by_source = {}

            for name, info in lock_pkgs.items():
                err = lock_package_error(name, info, lock_tag.lock)
                if err:
                    fail(err)

                source = info.get("source", "unknown")
                if source != "hosted":
                    skipped_by_source.setdefault(source, []).append(name)
                    continue

                # The hub aliases every package its lock names, explicit or not:
                # an explicit package stands in for the name everywhere, so a
                # hub that lists it points at the explicit repo, not a spoke.
                hub_packages[hub_name][name] = True

                if name in explicit:
                    continue  # pub.package() wins: no version to reconcile, no spoke

                desc = info.get("description", {})
                url = desc.get("url", "https://pub.dev")
                entry = struct(
                    version = info.get("version", ""),
                    sha256 = desc["sha256"],
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

    # Resolve each package to a single version
    resolved = {}  # pkg_name -> {version, sha256, url}
    for name, pkg in registry.items():
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

    # Create shared spoke repos
    all_package_names = sorted(resolved.keys())
    explicit_package_names = sorted(explicit.keys())
    for name, pkg in resolved.items():
        pub_lock_package(
            name = _SPOKE_PREFIX + "__" + name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            base_url = pkg.url,
            hub_name = _SPOKE_PREFIX,
            lock_packages = all_package_names,
            # A spoke whose pubspec depends on an explicit package depends on
            # that package's repo, which is what every hub aliases it to.
            explicit_packages = explicit_package_names,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
        )

    # Create per-from_lock hub repos
    for hub_name, packages in hub_packages.items():
        package_names = sorted(packages)
        pub_lock_hub(
            name = hub_name,
            hub_name = hub_name,
            spoke_prefix = _SPOKE_PREFIX,
            packages = package_names,
            explicit_packages = [n for n in package_names if n in explicit],
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
