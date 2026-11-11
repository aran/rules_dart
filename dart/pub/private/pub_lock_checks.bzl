"""What the `pub` extension refuses in the locks and declarations it reads.

Each check returns its messages instead of failing, so the extension reports
every refusal of a phase in one failure, as a user with several problems
would otherwise find them one run at a time.
"""

load("//dart/pub/private:pub_git.bzl", "is_relative_git_url", "pub_git_resolved_ref_error")

visibility("//dart/...")

def pub_command(subcommand, lock, packages = []):
    """The command that runs pub `subcommand` on the package that holds `lock`.

    `@rules_dart//dart/pub` needs only the `dart` toolchain, so it runs while
    the extension refuses a lock. It starts at the root of the workspace it
    is run in: the command is run from the root of the workspace that holds
    the lock, and `--directory` is the lock's directory there.

    Args:
        subcommand: The pub subcommand: `get` or `upgrade`.
        lock: The lock's label.
        packages: The packages to re-resolve, for `upgrade`.

    Returns:
        The command, to print on a line of its own.
    """
    path = lock.package + "/" + lock.name if lock.package else lock.name
    directory = path.rpartition("/")[0]
    words = ["bazel run @rules_dart//dart/pub --", subcommand]
    if directory:
        words.append("--directory=" + directory)
    return " ".join(words + packages)

def _normalize(path):
    # Collapses `.` and `..`, so two locks naming one directory by different
    # relative paths agree.
    absolute = path.startswith("/")
    parts = []
    for part in path.replace("\\", "/").split("/"):
        if part in ("", "."):
            continue
        if part == ".." and parts and parts[-1] != "..":
            parts.pop()
        else:
            parts.append(part)
    return ("/" if absolute else "") + "/".join(parts)

def _path_in_repo(lock, path):
    # The lock's relative `path`, from the root of the lock's repository; it
    # starts with `..` when it leaves the repository.
    return _normalize(lock.package + "/" + path if lock.package else path)

def _unbuildable_paths(lock):
    # The `build_from_pubspec` packages whose directory the lock names in a way
    # no repository attribute can hold on every machine: by an absolute path,
    # or by one leaving the lock's repository. MODULE.bazel.lock records every
    # repository's attributes, so it would hold only in this checkout.
    absolute = []
    outside = []
    for name in lock.tag.build_from_pubspec:
        info = lock.packages.get(name, {})
        if info.get("source") != "path":
            continue
        desc = info.get("description", {})
        path = desc.get("path", "")

        # The lock's scalars are read as strings: `true` is "True".
        if desc.get("relative", "").lower() != "true":
            absolute.append("`%s` (%s)" % (name, path))
        else:
            in_repo = _path_in_repo(lock.tag.lock, path)
            if in_repo == ".." or in_repo.startswith("../"):
                outside.append("`%s` (%s)" % (name, path))
    problems = []
    if absolute:
        problems.append(
            ("  - `build_from_pubspec` names %s, whose directory the lock gives by an absolute " +
             "path, which holds only on this machine. Give the package a relative `path:` in " +
             "the pubspec and run `dart pub get`, or map it with `resolve`.") % ", ".join(absolute),
        )
    if outside:
        problems.append(
            ("  - `build_from_pubspec` names %s, whose directory is outside the repository that " +
             "holds the lock. A repository builds only its own files; move the package into it, " +
             "or map it with `resolve` to a target that builds it, in a module " +
             "`local_path_override` brings in, say.") % ", ".join(outside),
        )
    return problems

def lock_mapping_error(lock):
    """What is wrong with how one `from_lock` call maps its lock's packages.

    A name `resolve`, `build_from_pubspec` or `ignored` gives that the lock
    does not list, a non-`path` package the last two name, a package named
    twice, a `path` package named nowhere, and a `build_from_pubspec` package
    whose directory no repository can hold.

    Args:
        lock: One lock, as the extension parses it: `struct(module, tag,
            packages)`.

    Returns:
        One message naming each problem, or None.
    """
    tag = lock.tag
    problems = []
    chosen = {}
    for attr_name, names in (("resolve", tag.resolve), ("build_from_pubspec", tag.build_from_pubspec), ("ignored", tag.ignored)):
        stale = sorted([name for name in names if name not in lock.packages])
        if stale:
            problems.append(
                "  - `%s` %s %s, which the lock does not list. Remove %s." % (
                    attr_name,
                    "maps" if attr_name == "resolve" else "names",
                    ", ".join(["`%s`" % n for n in stale]),
                    "them" if len(stale) > 1 else "it",
                ),
            )
        if attr_name != "resolve":
            not_path = sorted([
                name
                for name in names
                if name in lock.packages and lock.packages[name].get("source") != "path"
            ])
            if not_path:
                problems.append(
                    "  - `%s` names %s, which the lock does not list as `path`: it takes only path packages." % (
                        attr_name,
                        ", ".join(["`%s`" % n for n in not_path]),
                    ),
                )
        for name in names:
            chosen.setdefault(name, []).append(attr_name)
    for name in sorted(chosen):
        if len(chosen[name]) > 1:
            problems.append("  - `%s` is named in %s; name it in one." % (
                name,
                " and ".join(["`%s`" % a for a in chosen[name]]),
            ))
    unmapped = sorted([
        name
        for name, info in lock.packages.items()
        if info.get("source") == "path" and name not in chosen
    ])
    if unmapped:
        problems.append(
            ("  - it lists %s as %s. Name each in exactly one of:\n" +
             "      resolve = {%s}  (a target of yours builds it)\n" +
             "      build_from_pubspec = [%s]  (build it from its directory, as a hosted package)\n" +
             "      ignored = {%s}  (nothing builds it; depending on it fails with the reason)") % (
                ", ".join(["`%s`" % n for n in unmapped]),
                "`path` packages" if len(unmapped) > 1 else "a `path` package",
                ", ".join(['"%s": "//..."' % n for n in unmapped]),
                ", ".join(['"%s"' % n for n in unmapped]),
                ", ".join(['"%s": "<why>"' % n for n in unmapped]),
            ),
        )
    problems.extend(_unbuildable_paths(lock))
    if not problems:
        return None
    return "pub.from_lock(name = \"%s\", lock = \"%s\"):\n%s" % (tag.name, tag.lock, "\n".join(problems))

def resolved_packages(locks, declared):
    """Decides which locked packages a workspace target serves, from `resolve`.

    A mapped package is one target for the whole build, as every package is
    one repository, so two calls mapping it to different targets are refused,
    as is one mapping a package `pub.package()` also declares. Call it once
    every lock's `lock_mapping_error` is None.

    Args:
        locks: Every lock, as the extension parses them.
        declared: The packages a `pub.package()` requests.

    Returns:
        `struct(targets, errors)`: package name -> `struct(target,
        lock_label)`, the first mapping of each; and the messages.
    """
    targets = {}
    errors = []
    for lock in locks:
        tag = lock.tag
        for name, target in tag.resolve.items():
            if name in declared:
                errors.append(
                    ("Package \"%s\" is declared with `pub.package()` and mapped to %s by " +
                     "the `resolve` of the `pub.from_lock()` for %s. Each package is one " +
                     "repository or one target; keep one of the two.") % (name, target, tag.lock),
                )
            first = targets.setdefault(name, struct(target = target, lock_label = str(tag.lock)))
            if first.target != target:
                errors.append(
                    ("Package \"%s\" is mapped to different targets:\n" +
                     "  - %s (by the `resolve` of the `pub.from_lock()` for %s)\n" +
                     "  - %s (by the `resolve` of the `pub.from_lock()` for %s)\n" +
                     "rules_dart builds one copy of each package; map it to one target.") % (
                        name,
                        first.target,
                        first.lock_label,
                        target,
                        tag.lock,
                    ),
                )
    return struct(targets = targets, errors = errors)

def resolved_pubspecs(locks, resolved_targets):
    """The `resolve`-mapped packages whose pubspec the build can read.

    A mapped package is a target of the user's, whose dependencies its BUILD
    file states. Its pubspec states what pub sees it depend on, which is what
    finds a dependency cycle between it and pub packages, which no target can
    be built in. The pubspec is read where a lock lists the package by a
    relative `path` inside the lock's repository, which every checkout holds
    alike, as for `build_from_pubspec`. Call it once every lock's
    `lock_mapping_error` is None.

    Args:
        locks: Every lock, as the extension parses them.
        resolved_targets: `resolved_packages`'s targets.

    Returns:
        Package name -> `struct(target, path, version, lock)`: the target that
        builds it, and the first such lock's normalized `path` to it, version
        and label.
    """
    found = {}
    for lock in locks:
        tag = lock.tag
        for name in tag.resolve:
            info = lock.packages.get(name, {})
            desc = info.get("description", {})
            if name in found or info.get("source") != "path" or desc.get("relative", "").lower() != "true":
                continue
            in_repo = _path_in_repo(tag.lock, desc.get("path", ""))
            if in_repo == ".." or in_repo.startswith("../"):
                continue
            found[name] = struct(
                target = resolved_targets[name].target,
                path = _normalize(desc.get("path", "")),
                version = info.get("version", ""),
                lock = tag.lock,
            )
    return found

def path_packages(locks, declared, resolved_targets):
    """Collects the `path` packages each lock builds from its pubspec or ignores.

    Call it once every lock's `lock_mapping_error` is None: it reads each
    named package as the lock's `path` entry.

    Args:
        locks: Every lock, as the extension parses them.
        declared: The packages a `pub.package()` requests.
        resolved_targets: `resolved_packages`'s targets.

    Returns:
        `struct(built, ignored, errors)`: package name -> `struct(directory,
        path, version, lock, lock_label)`, package name -> `struct(reason,
        lock_label)`, and the messages. `directory` names the package's
        directory by its repository, for comparing and naming; `path` is the
        lock's path to it.
    """
    built = {}
    ignored = {}
    errors = []
    for lock in locks:
        tag = lock.tag
        for name in tag.build_from_pubspec + tag.ignored.keys():
            if name in declared:
                errors.append(("Package \"%s\" is declared with `pub.package()` and named by the " +
                               "`pub.from_lock()` for %s. Each package is one repository; keep one of the " +
                               "two.") % (name, tag.lock))
        for name in tag.build_from_pubspec:
            info = lock.packages[name]
            desc = info.get("description", {})
            path = desc.get("path", "")

            # `lock_mapping_error` has checked the path is relative and stays
            # in the lock's repository.
            directory = "@@%s//%s" % (tag.lock.repo_name, _path_in_repo(tag.lock, path))
            first = built.setdefault(name, struct(
                directory = directory,
                path = _normalize(path),
                version = info.get("version", ""),
                lock = tag.lock,
                lock_label = str(tag.lock),
            ))
            if first.directory != directory:
                errors.append(("Package \"%s\" is built from different directories:\n" +
                               "  - %s (by the `pub.from_lock()` for %s)\n" +
                               "  - %s (by the `pub.from_lock()` for %s)\n" +
                               "rules_dart builds one copy of each package; make the locks name one " +
                               "directory.") % (name, first.directory, first.lock_label, directory, tag.lock))
        for name, reason in tag.ignored.items():
            first = ignored.setdefault(name, struct(reason = reason, lock_label = str(tag.lock)))
            if first.reason != reason:
                ignored[name] = struct(reason = first.reason + "; " + reason, lock_label = first.lock_label + ", " + str(tag.lock))
    for name in built:
        if name in ignored:
            errors.append(("Package \"%s\" is built from its pubspec by the `pub.from_lock()` for %s and " +
                           "ignored by the one for %s. rules_dart builds one copy of each package; " +
                           "build it or ignore it everywhere.") % (name, built[name].lock_label, ignored[name].lock_label))
    for name in built.keys() + ignored.keys():
        if name in resolved_targets:
            errors.append(("Package \"%s\" is mapped by `resolve` in the `pub.from_lock()` for %s and " +
                           "named by `build_from_pubspec` or `ignored` in another. rules_dart builds one " +
                           "copy of each package; choose one.") % (name, resolved_targets[name].lock_label))
    return struct(built = built, ignored = ignored, errors = errors)

def git_lock_package(name, info, lock_tag):
    """Reads a lock's `source: git` entry, refusing one that pins nothing.

    Args:
        name: The package name.
        info: The lock entry.
        lock_tag: The `from_lock` tag whose lock lists it.

    Returns:
        `struct(package, errors)`: what is fetched for it, `struct(version,
        url, resolved_ref, path, lock, lock_label, lock_file)`, None when
        `errors` names why it cannot be.
    """
    desc = info.get("description", {})
    version = info.get("version", "")
    url = desc.get("url", "")
    resolved_ref = desc.get("resolved-ref", "")
    errors = []
    if not url:
        errors.append(("The git package \"%s\" %s (in %s) has no `description.url`. Re-resolve the " +
                       "lock to rewrite it, from the root of the workspace that holds it:\n  %s") % (
            name,
            version,
            lock_tag.lock,
            pub_command("get", lock_tag.lock),
        ))
    ref_error = pub_git_resolved_ref_error(
        name,
        version,
        resolved_ref,
        str(lock_tag.lock),
        rewrite = pub_command("get", lock_tag.lock),
    )
    if ref_error:
        errors.append(ref_error)
    if errors:
        return struct(package = None, errors = errors)
    return struct(
        package = struct(
            version = version,
            url = url,
            resolved_ref = resolved_ref,
            path = desc.get("path", "."),
            # A relative url is resolved against the lock's directory, so the
            # lock is part of what it names.
            lock = lock_tag.lock if is_relative_git_url(url) else None,
            lock_label = str(lock_tag.lock),
            lock_file = lock_tag.lock,
        ),
        errors = [],
    )

def git_disagreement_error(name, first, other):
    """Why two locks' entries for one git package cannot both be built, or None.

    Every lock that lists a git package must pin the same commit of the same
    repository directory: there is no version order between commits to
    upgrade along.

    Args:
        name: The package name.
        first: The first lock's entry, as `git_lock_package` reads it.
        other: Another lock's entry.

    Returns:
        The message, or None when they agree.
    """
    if (first.url, first.lock, first.resolved_ref, first.path) == (other.url, other.lock, other.resolved_ref, other.path):
        return None
    return ("Git package \"%s\" is locked differently across lock files:\n" +
            "  - %s at %s, path %s (from %s)\n" +
            "  - %s at %s, path %s (from %s)\n" +
            "rules_dart builds one copy of each package. Make the pubspecs ask for the " +
            "same commit, then re-resolve each lock from the root of the workspace that " +
            "holds it:\n  %s\n  %s") % (
        name,
        first.url,
        first.resolved_ref,
        first.path,
        first.lock_label,
        other.url,
        other.resolved_ref,
        other.path,
        other.lock_label,
        pub_command("upgrade", first.lock_file, [name]),
        pub_command("upgrade", other.lock_file, [name]),
    )

def source_disagreement_errors(built, git, hosted):
    """Why a package two locks list from different sources cannot be built.

    Args:
        built: The `path` packages built from their pubspec, as
            `path_packages` gives them.
        git: Package name -> the git package fetched for it.
        hosted: Package name -> its hosted lock entries, each with a
            `lock_label`.

    Returns:
        The messages, one per package.
    """
    errors = []
    for name, path_pkg in built.items():
        if name in hosted or name in git:
            errors.append(
                ("Package \"%s\" is built from %s by the `pub.from_lock()` for %s, and another " +
                 "lock lists it as a %s package. rules_dart builds one copy of each package; " +
                 "make the locks agree.") % (
                    name,
                    path_pkg.directory,
                    path_pkg.lock_label,
                    "hosted" if name in hosted else "git",
                ),
            )
    for name, git_pkg in git.items():
        if name in hosted:
            errors.append(
                ("Package \"%s\" is a git package in %s and a hosted package in %s. " +
                 "rules_dart builds one copy of each package; make the locks agree, " +
                 "or declare it with `pub.package()` in the root module.") % (
                    name,
                    git_pkg.lock_label,
                    hosted[name][0].lock_label,
                ),
            )
    return errors
