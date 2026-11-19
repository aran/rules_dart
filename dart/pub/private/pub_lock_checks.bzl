"""What the `pub` extension refuses in the locks and declarations it reads.

Each check returns its messages instead of failing, so the extension reports
every refusal of a phase in one failure, as a user with several problems
would otherwise find them one run at a time.

`pub_lock_mapping_error`, `pub_lock_entry` and `pub_lock_disagreement_errors`
take nothing of the extension's own, so that another pub extension refuses the
same locks: `pub_lock_package.bzl` exports them.
"""

load("//dart/private:package_info.bzl", "fetched_identity_text")
load("//dart/pub/private:build_content.bzl", "is_pub_dev", "pub_git_source", "pub_path_is_outside", "pub_path_source", _normalize = "normalize_pub_path", _path_in_repo = "lock_path_in_repo")
load("//dart/pub/private:pub_archive.bzl", "pub_archive_sha256_error")
load("//dart/pub/private:pub_git.bzl", "is_relative_git_url", "pub_git_resolved_ref_error")
load("//dart/pub/private:pub_path.bzl", "pub_lock_path_location")

visibility("//dart/...")

# The packages this repository publishes to pub.dev, each with the target it
# publishes. See `published_here_targets`.
_PUBLISHED_HERE = {"runfiles": Label("//dart/runfiles")}

# What runs pub for this extension's users.
_RUNNER = "@rules_dart//dart/pub"

def pub_command(subcommand, lock, packages = [], runner = _RUNNER):
    """The command that runs pub `subcommand` on the package that holds `lock`.

    `@rules_dart//dart/pub` needs only the `dart` toolchain, so it runs while
    the extension refuses a lock. It starts at the root of the workspace it
    is run in: the command is run from the root of the workspace that holds
    the lock, and `--directory` is the lock's directory there.

    Args:
        subcommand: The pub subcommand: `get` or `upgrade`.
        lock: The lock's label.
        packages: The packages to re-resolve, for `upgrade`.
        runner: The target that runs pub.

    Returns:
        The command, to print on a line of its own.
    """
    path = lock.package + "/" + lock.name if lock.package else lock.name
    directory = path.rpartition("/")[0]
    words = ["bazel run %s --" % runner, subcommand]
    if directory:
        words.append("--directory=" + directory)
    return " ".join(words + packages)

def _suggested_target(lock, info):
    # What `resolve` most likely maps a `path` package to: the Bazel package
    # at its directory, where the lock's repository holds one.
    path = info.get("description", {}).get("path", "")
    if pub_path_is_outside(lock, path):
        return "//..."
    return "//%s:<target>" % _path_in_repo(lock, path)

def pub_lock_mapping_error(call, lock, packages, resolve = {}, build_from_pubspec = [], ignored = {}):
    """What is wrong with how one call of a `from_lock` tag maps its lock's packages.

    A lock's `path` packages name directories only its author knows how to
    build, so each must be named in exactly one of three attributes: `resolve`
    (a target builds it), `build_from_pubspec` (its directory is built as a
    hosted package is) or `ignored` (nothing builds it, for a reason).

    Refused: a name the lock does not list, a non-`path` package in
    `build_from_pubspec` or `ignored`, a package named twice, and a `path`
    package named nowhere. Where the directory is, outside the lock's repository
    too, is the lock's to say, as it is pub's.

    Args:
        call: The tag as the message's heading names it, such as
            `pub.from_lock(name = "deps", lock = "//:pubspec.lock")`.
        lock: The lock's `Label`.
        packages: The lock's packages, as `parse_pubspec_lock` gives them.
        resolve: The names `resolve` maps: a dict by package name, or a list.
        build_from_pubspec: The names built from their pubspec.
        ignored: The names ignored: a dict by package name, or a list.

    Returns:
        One message naming each problem, or None.
    """
    problems = []
    chosen = {}
    for attr_name, names in (("resolve", resolve), ("build_from_pubspec", build_from_pubspec), ("ignored", ignored)):
        stale = sorted([name for name in names if name not in packages])
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
                if name in packages and packages[name].get("source") != "path"
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
        for name, info in packages.items()
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
                ", ".join(['"%s": "%s"' % (n, _suggested_target(lock, packages[n])) for n in unmapped]),
                ", ".join(['"%s"' % n for n in unmapped]),
                ", ".join(['"%s": "<why>"' % n for n in unmapped]),
            ),
        )
    if not problems:
        return None
    return "%s:\n%s" % (call, "\n".join(problems))

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

def published_declaration_errors(declared, published = _PUBLISHED_HERE):
    """Why a `pub.package()` of a package rules_dart publishes cannot stand.

    It states a version and a digest, and the build would serve the target that
    came with the rules whatever they say (`published_here_targets`). Nobody who
    wrote down a version should silently get other code.

    Args:
        declared: Package name -> where each `pub.package()` of it is, for the
            message.
        published: Package name -> the target publishing it.

    Returns:
        The messages, one per such package.
    """
    return [
        ("`pub.package(name = \"%s\")` (in %s) names a package rules_dart publishes. A build " +
         "holds the copy that came with the rules, @rules_dart//%s, so the version and sha256 " +
         "would not be used. Remove the declaration and depend on that target.") % (
            name,
            ", ".join(declared[name]),
            published[name].package,
        )
        for name in sorted(declared)
        if name in published
    ]

def published_here_targets(locks, targets, published = _PUBLISHED_HERE):
    """`targets` with the packages rules_dart itself publishes to pub.dev.

    `runfiles` reaches a build two ways: as `@rules_dart//dart/runfiles`, and
    from pub.dev, where each rules_dart release publishes those sources. Those
    are one package, so a build holds one copy, the one that came with the
    rules: it knows the runfiles layout of the rules_dart building it, whichever
    release a lock happened to resolve. It is `resolve` stated by the package's
    publisher, so nothing about comparing packages changes, and the package's
    users compile against one library. A lock's version of it is not compared,
    as with any `resolve`; code the rules' copy does not fit fails to compile.

    Only pub.dev's package is this one. A `runfiles` from another registry, git
    or a path is some other package of that name, and so is the build's to
    place. The user's own `resolve` of it wins. A lock lists what pub resolved,
    so serving it this way overrides no one's choice; a `pub.package()` states
    one, and is refused (`published_declaration_errors`).

    Args:
        locks: Every lock, as the extension parses them.
        targets: `resolved_packages`'s targets.
        published: Package name -> the target publishing it.

    Returns:
        `targets`, with an entry for each published package a lock takes from
        pub.dev and the build does not map itself.
    """
    result = dict(targets)
    served = published_by_rules_dart([lock.packages for lock in locks], published)
    for name, target in served.items():
        if name not in targets:
            result[name] = struct(target = target, lock_label = str(target))
    return result

def published_by_rules_dart(lock_packages, published = _PUBLISHED_HERE):
    """The packages a build's locks take from pub.dev that rules_dart itself publishes.

    Such a package is one package with its target in rules_dart, so an extension
    serving pub packages should map it to that target unless the user's own
    `resolve` maps it. See `published_here_targets`.

    Args:
        lock_packages: The `packages` of each lock, as `parse_pubspec_lock` returns them.
        published: Package name -> the target publishing it.

    Returns:
        A dict of package name to the `Label` of the target publishing it, for
        each such package every lock listing it takes from pub.dev.
    """
    result = {}
    for name, target in published.items():
        listed = [packages[name] for packages in lock_packages if name in packages]
        if listed and all([_from_pub_dev(info) for info in listed]):
            result[name] = target
    return result

def _from_pub_dev(info):
    return info["source"] == "hosted" and is_pub_dev(info.get("description", {}).get("url", "https://pub.dev"))

def resolved_pubspecs(locks, resolved_targets):
    """The `resolve`-mapped packages whose pubspec the build can read.

    A mapped package is a target of the user's, whose dependencies its BUILD
    file states. Its pubspec states what pub sees it depend on, which is what
    finds a dependency cycle between it and pub packages, which no target can
    be built in. The pubspec is read where the first lock listing the package
    by a `path` says it is. Call it once every lock's `lock_mapping_error` is
    None.

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
            if name in found or info.get("source") != "path":
                continue
            found[name] = struct(
                target = resolved_targets[name].target,
                path = _normalize(info.get("description", {}).get("path", "")),
                version = info.get("version", ""),
                lock = tag.lock,
            )
    return found

def path_packages(ctx, locks, declared, resolved_targets):
    """Collects the `path` packages each lock builds from its pubspec or ignores.

    Call it once every lock's `lock_mapping_error` is None: it reads each
    named package as the lock's `path` entry.

    Args:
        ctx: The `module_ctx`, which finds where each directory is.
        locks: Every lock, as the extension parses them.
        declared: The packages a `pub.package()` requests.
        resolved_targets: `resolved_packages`'s targets.

    Returns:
        `struct(built, entries, ignored, errors)`: package name -> its first
        `pub_lock_entry`, package name -> every such entry, package name ->
        `struct(reason, lock_label)`, and the messages.
    """
    built = {}
    entries = {}
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
            read = pub_lock_entry(name, lock.packages[name], tag.lock, ctx = ctx)
            errors.extend(read.errors)
            if read.entry:
                built.setdefault(name, read.entry)
                entries.setdefault(name, []).append(read.entry)
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
    return struct(built = built, entries = entries, ignored = ignored, errors = errors)

def _git_entry(name, info, common):
    desc = info.get("description", {})
    version = common["version"]
    url = desc.get("url", "")
    resolved_ref = desc.get("resolved-ref", "")
    lock_file = common["lock_file"]
    errors = []
    if not url:
        errors.append(("The git package \"%s\" %s (in %s) has no `description.url`. Re-resolve the " +
                       "lock to rewrite it, from the root of the workspace that holds it:\n  %s") % (
            name,
            version,
            lock_file,
            common["refresh"],
        ))
    ref_error = pub_git_resolved_ref_error(
        name,
        version,
        resolved_ref,
        str(lock_file),
        rewrite = common["refresh"],
    )
    if ref_error:
        errors.append(ref_error)
    if errors:
        return struct(entry = None, errors = errors)

    # A relative url is resolved against the lock's directory, so the lock is
    # part of what it names.
    lock = lock_file if is_relative_git_url(url) else None
    path = _normalize(desc.get("path", ".")) or "."
    return struct(
        entry = struct(
            url = url,
            resolved_ref = resolved_ref,
            path = path,
            lock = lock,
            identity = pub_git_source(name, version, url, resolved_ref, path, lock).identity,
            **common
        ),
        errors = [],
    )

def _hosted_entry(name, info, common):
    desc = info.get("description", {})
    sha256 = desc.get("sha256", "")
    error = pub_archive_sha256_error(
        name,
        common["version"],
        sha256,
        common["lock_label"],
        rewrite = common["refresh"],
    )
    if error:
        # An entry that pins nothing requests nothing.
        return struct(entry = None, errors = [error])
    return struct(
        entry = struct(sha256 = sha256, url = desc.get("url", "https://pub.dev"), **common),
        errors = [],
    )

def _path_entry(name, info, common, ctx):
    path = info.get("description", {}).get("path", "")
    lock = common["lock_file"]
    outside = pub_path_is_outside(lock, path)
    if outside and ctx == None:
        fail(("Package \"%s\" is at `%s` from %s, outside the lock's repository: give " +
              "`pub_lock_entry` the `ctx` that can find it.") % (name, path, common["lock_label"]))
    location = pub_lock_path_location(ctx, lock, path) if ctx else None
    return struct(
        entry = struct(
            path = _normalize(path),
            outside = outside,
            location = location,
            directory = location if outside else fetched_identity_text(pub_path_source(lock, path).identity),
            **common
        ),
        errors = [],
    )

def pub_lock_entry(name, info, lock, runner = _RUNNER, ctx = None):
    """Reads one package of a lock, refusing what could not be fetched from it.

    A hosted entry must pin its archive's sha256, and a git entry a url and a
    full commit. Read only the `path` packages built from their pubspec, those
    `pub_lock_mapping_error` has checked.

    Args:
        name: The package name.
        info: Its entry, from `parse_pubspec_lock`'s `packages`.
        lock: The lock's `Label`.
        runner: The target whose `bazel run` runs pub, for the commands the
            messages and the entry give.
        ctx: The `module_ctx`. A `path` entry needs it to find its directory
            when that is outside the lock's repository, and to be compared
            with one that is. Reading such an entry without it fails.

    Returns:
        `struct(entry, errors)`: the messages, and the entry, None when they
        say it cannot be used. Every entry has `source`, `version`,
        `lock_file` (the lock's `Label`), `lock_label` (its text), `refresh`
        (the `pub get` that rewrites the lock) and `upgrade` (the `pub upgrade`
        of this package). Besides those,
        - hosted: `sha256`, `url`.
        - git: `url`, `resolved_ref`, `path` (normalized, "." for the root),
          `lock` (the lock's `Label` when `url` is relative to it, else None)
          and `identity` (`pub_git_source`'s).
        - path: `path` (normalized, absolute if the lock's is); `outside`,
          whether it is outside the lock's repository (`pub_path_is_outside`),
          which decides how it is compared; `location`, where it is on this
          machine (`pub_lock_path_location`), None without `ctx`; and
          `directory`, for messages: its name by its repository, or its
          location when outside. Give `lock_file` and `path` to
          `pub_lock_path_directory`, or to the repository rule, which is
          `local` wherever the directory is.
    """
    common = dict(
        source = info.get("source", ""),
        version = info.get("version", ""),
        lock_file = lock,
        lock_label = str(lock),
        refresh = pub_command("get", lock, runner = runner),
        upgrade = pub_command("upgrade", lock, [name], runner = runner),
    )
    if common["source"] == "hosted":
        return _hosted_entry(name, info, common)
    if common["source"] == "git":
        return _git_entry(name, info, common)
    if common["source"] == "path":
        return _path_entry(name, info, common, ctx)
    return struct(entry = struct(**common), errors = [])

def git_disagreement_error(name, first, other):
    """Why two locks' entries for one git package cannot both be built, or None.

    Every lock that lists a git package must pin the same commit of the same
    repository directory: there is no version order between commits to
    upgrade along. Two entries are one package when `pub_git_source` gives them
    one identity, however each spells the repository's place or the directory.
    An entry with no identity, a relative url leaving the lock's repository,
    agrees only with its own lock's.

    Args:
        name: The package name.
        first: The first lock's entry, as `pub_lock_entry` reads it.
        other: Another lock's entry.

    Returns:
        The message, or None when they agree.
    """
    if first.identity != None or other.identity != None:
        if first.identity == other.identity:
            return None
    elif (first.url, first.lock, first.resolved_ref, first.path) == (other.url, other.lock, other.resolved_ref, other.path):
        return None
    one_commit = first.resolved_ref == other.resolved_ref and first.path == other.path
    if one_commit and (first.url != other.url or first.identity == None):
        remedy = ("Both are at one commit, and nothing says their urls name one repository. " +
                  "Have the pubspecs name it by one url that does not depend on where the lock is")
    else:
        remedy = "Make the pubspecs ask for the same commit"
    return ("Git package \"%s\" is locked differently across lock files:\n" +
            "  - %s at %s, path %s (from %s)\n" +
            "  - %s at %s, path %s (from %s)\n" +
            "A build holds one copy of each package. %s, then re-resolve each lock " +
            "from the root of the workspace that holds it:\n  %s\n  %s") % (
        name,
        first.url,
        first.resolved_ref,
        first.path,
        first.lock_label,
        other.url,
        other.resolved_ref,
        other.path,
        other.lock_label,
        remedy,
        first.upgrade,
        other.upgrade,
    )

def _same_directory(one, other):
    # By name inside a repository, which holds on every machine. An entry
    # outside one has only its place on this machine to be compared by.
    if getattr(one, "outside", False) or getattr(other, "outside", False):
        return getattr(one, "location", None) == getattr(other, "location", None)
    return one.directory == other.directory

def pub_lock_disagreement_errors(name, entries):
    """Why the locks listing one package cannot all be built, with one copy of it.

    Two `path` entries must name one directory, however each spells it, and
    two git entries one commit of one repository directory
    (`git_disagreement_error`), and a package may
    come from only one of `path`, git and a registry. Which version of a hosted
    package wins is `select_pub_version`'s to say. An entry of any other source
    is not compared.

    Args:
        name: The package name.
        entries: Its `pub_lock_entry` entries, the first of each source being
            the one the build would use. Leave out those of a lock whose entry
            does not count: one the root module's lock overrides, or a package
            `resolve` maps to a target.

    Returns:
        The messages.
    """
    paths = [e for e in entries if e.source == "path"]
    gits = [e for e in entries if e.source == "git"]
    hosted = [e for e in entries if e.source == "hosted"]
    agree = "A build holds one copy of each package; make the locks agree, or map it to one target with `resolve`."
    errors = []
    for other in paths[1:]:
        if not _same_directory(paths[0], other):
            errors.append(("Package \"%s\" is built from different directories:\n" +
                           "  - %s (by the lock %s)\n" +
                           "  - %s (by the lock %s)\n" +
                           "%s") % (name, paths[0].directory, paths[0].lock_label, other.directory, other.lock_label, agree))
    for other in gits[1:]:
        error = git_disagreement_error(name, gits[0], other)
        if error:
            errors.append(error)
    if paths and (gits or hosted):
        other = hosted[0] if hosted else gits[0]
        errors.append("Package \"%s\" is built from %s by the lock %s, and the lock %s lists it as a %s package. %s" % (
            name,
            paths[0].directory,
            paths[0].lock_label,
            other.lock_label,
            other.source,
            agree,
        ))
    elif gits and hosted:
        errors.append("Package \"%s\" is a git package in %s and a hosted package in %s. %s" % (
            name,
            gits[0].lock_label,
            hosted[0].lock_label,
            agree,
        ))
    return errors
