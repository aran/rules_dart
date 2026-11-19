"""Unit tests for dart/pub/private/pub_lock_checks.bzl.

The `pub` extension refuses a lock whose mapping of its packages is wrong,
locks that disagree on what serves a package, and a git entry that pins
nothing. Each check returns its messages, so the extension can report every
refusal of a phase at once.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//dart/pub:pub_lock_package.bzl",
    "pub_lock_disagreement_errors",
    "pub_lock_entry",
    "pub_lock_mapping_error",
    "pub_lock_path_directory",
)

# buildifier: disable=bzl-visibility
load("//dart/pub/private:build_content.bzl", "normalize_pub_path", "pub_path_is_outside", "pub_path_root")

# buildifier: disable=bzl-visibility
load(
    "//dart/pub/private:pub_lock_checks.bzl",
    "git_disagreement_error",
    "path_packages",
    "pub_command",
    "published_by_rules_dart",
    "published_declaration_errors",
    "published_here_targets",
    "resolved_packages",
    "resolved_pubspecs",
)
load(":small_suite.bzl", "small_unittest_suite")

_COMMIT_A = "0123456789abcdef0123456789abcdef01234567"
_COMMIT_B = "89abcdef0123456789abcdef0123456789abcdef"

def _contains(env, text, *fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "expected {} in:\n{}".format(repr(fragment), text))

def _tag(lock, name = "deps", resolve = {}, build_from_pubspec = [], ignored = {}):
    return struct(name = name, lock = Label(lock), resolve = resolve, build_from_pubspec = build_from_pubspec, ignored = ignored)

def _lock(packages, **kwargs):
    lock = kwargs.pop("lock", "//app:pubspec.lock")
    return struct(module = None, tag = _tag(lock, **kwargs), packages = packages)

def lock_mapping_error(lock):
    tag = lock.tag
    return pub_lock_mapping_error(
        'pub.from_lock(name = "%s", lock = "%s")' % (tag.name, tag.lock),
        tag.lock,
        lock.packages,
        resolve = tag.resolve,
        build_from_pubspec = tag.build_from_pubspec,
        ignored = tag.ignored,
    )

def _entry(lock, info, name = "foo"):
    read = pub_lock_entry(name, info, Label(lock))
    return read.entry

def _hosted(version = "1.0.0"):
    return {"source": "hosted", "version": version, "description": {"sha256": "0" * 64}}

def _path(path, relative = "True"):
    return {"source": "path", "version": "0.1.0", "description": {"path": path, "relative": relative}}

def _git(url = "https://example.invalid/foo.git", ref = _COMMIT_A, path = "."):
    desc = {"path": path}
    if url:
        desc["url"] = url
    if ref != None:
        desc["resolved-ref"] = ref
    return {"source": "git", "version": "1.0.0", "description": desc}

def _pub_command_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "bazel run @rules_dart//dart/pub -- get", pub_command("get", Label("//:pubspec.lock")))
    asserts.equals(
        env,
        "bazel run @rules_dart//dart/pub -- upgrade --directory=app/sub foo",
        pub_command("upgrade", Label("//app/sub:pubspec.lock"), ["foo"]),
    )
    asserts.equals(
        env,
        "bazel run @other//pub -- get --directory=app",
        pub_command("get", Label("//app:pubspec.lock"), runner = "@other//pub"),
    )
    return unittest.end(env)

def _mapping_accepts_every_path_package_named_once_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = _lock(
        {"a": _path("../a"), "b": _path("b"), "c": _path("c"), "http": _hosted()},
        resolve = {"a": "//a", "http": "//http"},
        build_from_pubspec = ["b"],
        ignored = {"c": "an editor's"},
    )
    asserts.equals(env, None, lock_mapping_error(lock))

    # A lock named `sub/pubspec.lock` sits in `app/sub/`, so `../../x` is
    # `x`, inside the repository; from `app/` it would leave it.
    nested = _lock({"x": _path("../../x")}, lock = "//app:sub/pubspec.lock", build_from_pubspec = ["x"])
    asserts.equals(env, None, lock_mapping_error(nested))
    return unittest.end(env)

def _mapping_names_each_problem_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = _lock(
        {
            "models": _path("models"),
            "utils": _path("utils"),
            "path": _hosted(),
            "far": _path("/opt/far", relative = "False"),
            "outside": _path("../../outside"),
        },
        resolve = {"http": "//http"},
        build_from_pubspec = ["path", "utils", "far", "outside"],
        ignored = {"utils": "twice", "gone": "stale"},
    )
    error = lock_mapping_error(lock)
    _contains(
        env,
        error,
        'pub.from_lock(name = "deps", lock = "@@//app:pubspec.lock"):',
        "  - `resolve` maps `http`, which the lock does not list. Remove it.",
        "  - `ignored` names `gone`, which the lock does not list. Remove it.",
        "  - `build_from_pubspec` names `path`, which the lock does not list as `path`",
        "  - `utils` is named in `build_from_pubspec` and `ignored`; name it in one.",
        "  - it lists `models` as a `path` package.",
        'resolve = {"models": "//app/models:<target>"}',
        'build_from_pubspec = ["models"]',
    )

    # A directory outside the repository is the lock's to name.
    asserts.true(env, "`far`" not in error and "`outside`" not in error, error)
    return unittest.end(env)

def _resolve_agreement_test_impl(ctx):
    env = unittest.begin(ctx)
    one = _lock({"a": _path("a")}, lock = "//one:pubspec.lock", resolve = {"a": "//a"})
    same = _lock({"a": _path("a")}, lock = "//same:pubspec.lock", resolve = {"a": "//a"})
    other = _lock({"a": _path("a"), "b": _hosted()}, lock = "//other:pubspec.lock", resolve = {"a": "//other_a", "b": "//b"})

    agreed = resolved_packages([one, same], {})
    asserts.equals(env, [], agreed.errors)
    asserts.equals(env, "//a", agreed.targets["a"].target)
    asserts.equals(env, "@@//one:pubspec.lock", agreed.targets["a"].lock_label)

    refused = resolved_packages([one, other], {"b": []})
    asserts.equals(env, 2, len(refused.errors))
    _contains(env, refused.errors[0], "Package \"a\" is mapped to different targets:", "  - //a (by", "  - //other_a (by")
    _contains(env, refused.errors[1], "Package \"b\" is declared with `pub.package()` and mapped to //b")
    return unittest.end(env)

def _path_agreement_test_impl(ctx):
    env = unittest.begin(ctx)
    one = _lock({"m": _path("m"), "i": _path("i")}, lock = "//one:pubspec.lock", build_from_pubspec = ["m", "i"])
    two = _lock({"m": _path("../elsewhere/m"), "i": _path("i"), "d": _path("d")}, lock = "//two:pubspec.lock", build_from_pubspec = ["m"], ignored = {"i": "unused", "d": "declared"})
    r = _lock({"m": _path("m")}, lock = "//r:pubspec.lock", resolve = {"m": "//m"})

    agreed = path_packages(None, [one], {}, {})
    asserts.equals(env, [], agreed.errors)
    asserts.equals(env, "@@//one/m", agreed.built["m"].directory)

    refused = path_packages(None, [one, two, r], {"d": []}, resolved_packages([r], {}).targets)
    _contains(env, "\n".join(refused.errors), "Package \"d\" is declared with `pub.package()` and named by the `pub.from_lock()` for @@//two:pubspec.lock")
    _contains(
        env,
        "\n".join(pub_lock_disagreement_errors("m", refused.entries["m"])),
        "Package \"m\" is built from different directories:",
        "  - @@//one/m (by the lock @@//one:pubspec.lock)",
        "  - @@//elsewhere/m (by the lock @@//two:pubspec.lock)",
    )
    _contains(env, "\n".join(refused.errors), "Package \"i\" is built from its pubspec by the `pub.from_lock()` for @@//one:pubspec.lock and ignored by the one for @@//two:pubspec.lock")
    _contains(env, "\n".join(refused.errors), "Package \"m\" is mapped by `resolve` in the `pub.from_lock()` for @@//r:pubspec.lock")
    return unittest.end(env)

def _git_entry_pinned_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = Label("//app:pubspec.lock")
    read = pub_lock_entry("foo", _git(), lock)
    asserts.equals(env, [], read.errors)
    asserts.equals(env, "git", read.entry.source)
    asserts.equals(env, _COMMIT_A, read.entry.resolved_ref)
    asserts.equals(env, None, read.entry.lock, "an absolute url names no lock")
    asserts.equals(env, lock, read.entry.lock_file)

    relative = pub_lock_entry("foo", _git(url = "../foo"), lock)
    asserts.equals(env, lock, relative.entry.lock, "a relative url is resolved against the lock")
    return unittest.end(env)

def _git_entry_unpinned_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = Label("//app:pubspec.lock")
    short = pub_lock_entry("foo", _git(ref = "a1b2c3d"), lock)
    asserts.equals(env, None, short.entry)
    asserts.equals(env, 1, len(short.errors))
    _contains(
        env,
        short.errors[0],
        'resolved-ref "a1b2c3d", which is not a full commit id',
        "bazel run @rules_dart//dart/pub -- get --directory=app",
    )

    neither = pub_lock_entry("foo", _git(url = "", ref = None), lock)
    asserts.equals(env, None, neither.entry)
    asserts.equals(env, 2, len(neither.errors), "a missing url and a missing commit are each named")
    _contains(env, neither.errors[0], 'The git package "foo" 1.0.0 (in @@//app:pubspec.lock) has no `description.url`.')
    _contains(env, neither.errors[1], 'resolved-ref "", which is not a full commit id')
    return unittest.end(env)

def _git_disagreement_test_impl(ctx):
    env = unittest.begin(ctx)
    one = _entry("//one:pubspec.lock", _git())
    same = _entry("//same:pubspec.lock", _git())
    other = _entry("//two:pubspec.lock", _git(ref = _COMMIT_B))
    subdir = _entry("//sub:pubspec.lock", _git(path = "pkgs/foo"))

    asserts.equals(env, None, git_disagreement_error("foo", one, same))
    _contains(
        env,
        git_disagreement_error("foo", one, other),
        "Git package \"foo\" is locked differently across lock files:",
        "  - https://example.invalid/foo.git at %s, path . (from @@//one:pubspec.lock)" % _COMMIT_A,
        "  - https://example.invalid/foo.git at %s, path . (from @@//two:pubspec.lock)" % _COMMIT_B,
        "  bazel run @rules_dart//dart/pub -- upgrade --directory=one foo",
        "  bazel run @rules_dart//dart/pub -- upgrade --directory=two foo",
    )
    asserts.true(env, git_disagreement_error("foo", one, subdir) != None, "another directory of one commit disagrees")

    # A relative url names a repository by the lock's directory.
    rel_one = _entry("//a/one:pubspec.lock", _git(url = "../foo"))
    rel_two = _entry("//b/two:pubspec.lock", _git(url = "../foo"))
    asserts.true(env, git_disagreement_error("foo", rel_one, rel_two) != None, "one relative url from two directories")
    return unittest.end(env)

def _git_agreement_is_identity_test_impl(ctx):
    # Two locks agree when `pub_git_source` calls their entries one package,
    # however each spells where it is.
    env = unittest.begin(ctx)

    def entry(lock, **kwargs):
        return _entry(lock, _git(**kwargs))

    # One repository, reached from two directories.
    near = entry("//shared/app:pubspec.lock", url = "../foo")
    far = entry("//shared/deep/app:pubspec.lock", url = "../../foo")
    asserts.equals(env, None, git_disagreement_error("foo", near, far))

    # One directory of it, spelled three ways.
    root = entry("//one:pubspec.lock")
    for path in ("./", ""):
        asserts.equals(env, None, git_disagreement_error("foo", root, entry("//two:pubspec.lock", path = path)))
    pkg = entry("//one:pubspec.lock", path = "pkgs/foo")
    asserts.equals(env, None, git_disagreement_error("foo", pkg, entry("//two:pubspec.lock", path = "./pkgs/foo/")))

    # What is fetched is the normalized path: git reads `./` as something else.
    asserts.equals(env, ".", entry("//two:pubspec.lock", path = "./").path)
    asserts.equals(env, "pkgs/foo", entry("//two:pubspec.lock", path = "./pkgs/foo/").path)

    # Two urls at one commit may be two repositories, and asking for the same
    # commit, which they already do, would not help.
    mirror = entry("//two:pubspec.lock", url = "https://mirror.example.invalid/foo.git")
    _contains(
        env,
        git_disagreement_error("foo", root, mirror),
        "Both are at one commit",
        "one url",
        "  bazel run @rules_dart//dart/pub -- upgrade --directory=one foo",
    )
    asserts.true(env, "same commit" not in git_disagreement_error("foo", root, mirror))

    # Urls leaving the lock's repository name nothing to compare...
    out_one = entry("//one:pubspec.lock", url = "../../foo")
    out_two = entry("//two:pubspec.lock", url = "../../foo")
    _contains(env, git_disagreement_error("foo", out_one, out_two), "Both are at one commit")

    # ...unless they are one lock's.
    again = entry("//one:pubspec.lock", url = "../../foo", path = "./")
    asserts.equals(env, None, git_disagreement_error("foo", out_one, again))
    return unittest.end(env)

def _source_disagreement_test_impl(ctx):
    env = unittest.begin(ctx)
    git = _entry("//one:pubspec.lock", _git())
    hosted = _entry("//two:pubspec.lock", _hosted())
    path = _entry("//three:pubspec.lock", _path("p"))
    _contains(
        env,
        "\n".join(pub_lock_disagreement_errors("foo", [git, hosted])),
        "Package \"foo\" is a git package in @@//one:pubspec.lock and a hosted package in @@//two:pubspec.lock.",
        "map it to one target with `resolve`",
    )
    _contains(
        env,
        "\n".join(pub_lock_disagreement_errors("foo", [path, git])),
        "Package \"foo\" is built from @@//three/p by the lock @@//three:pubspec.lock, and the lock @@//one:pubspec.lock lists it as a git package.",
    )
    _contains(
        env,
        "\n".join(pub_lock_disagreement_errors("foo", [hosted, path])),
        "Package \"foo\" is built from @@//three/p by the lock @@//three:pubspec.lock, and the lock @@//two:pubspec.lock lists it as a hosted package.",
    )
    other_hosted = _entry("//four:pubspec.lock", _hosted("2.0.0"))
    asserts.equals(env, [], pub_lock_disagreement_errors("foo", [hosted, other_hosted]), "`select_pub_version` picks among hosted entries")
    asserts.equals(env, [], pub_lock_disagreement_errors("foo", [path, _entry("//three:pubspec.lock", _path("./p/"))]))
    sdk = _entry("//five:pubspec.lock", {"source": "sdk", "version": "0.0.0", "description": {"name": "flutter"}})
    asserts.equals(env, [], pub_lock_disagreement_errors("foo", [hosted, sdk]), "other sources are not compared")
    return unittest.end(env)

def _entries_test_impl(ctx):
    env = unittest.begin(ctx)
    lock = Label("//app:pubspec.lock")
    runner = "@other//pub"

    hosted = pub_lock_entry("foo", _hosted("1.2.3"), lock, runner = runner).entry
    asserts.equals(env, ("hosted", "1.2.3", "0" * 64, "https://pub.dev"), (hosted.source, hosted.version, hosted.sha256, hosted.url))
    asserts.equals(env, "bazel run @other//pub -- get --directory=app", hosted.refresh)
    asserts.equals(env, "bazel run @other//pub -- upgrade --directory=app foo", hosted.upgrade)

    unpinned = pub_lock_entry("foo", {"source": "hosted", "version": "1.0.0", "description": {}}, lock, runner = runner)
    asserts.equals(env, None, unpinned.entry)
    _contains(env, unpinned.errors[0], 'No sha256 is pinned for pub package "foo"', "bazel run @other//pub -- get --directory=app")

    path = pub_lock_entry("foo", _path("../pkgs/./foo/"), lock).entry
    asserts.equals(env, ("../pkgs/foo", "@@//pkgs/foo", lock), (path.path, path.directory, path.lock_file))

    asserts.equals(env, (False, None), (path.outside, path.location))
    return unittest.end(env)

def _path_entry(directory, location = None, outside = False, lock = "//a:pubspec.lock"):
    return struct(source = "path", directory = directory, location = location, outside = outside, lock_label = lock)

def _path_disagreement_test_impl(ctx):
    env = unittest.begin(ctx)

    def errors(*entries):
        return pub_lock_disagreement_errors("p", list(entries))

    # Inside a repository, entries are compared by name, on every machine.
    asserts.equals(env, [], errors(_path_entry("@@//p", "/here/p"), _path_entry("@@//p", "/elsewhere/p")))
    asserts.equals(env, 1, len(errors(_path_entry("@@//p", "/here/p"), _path_entry("@@//q", "/here/p"))))

    # An entry outside one is compared by where it is, with any other.
    outside = _path_entry("/there/p", "/there/p", outside = True)
    asserts.equals(env, [], errors(outside, _path_entry("/there/p", "/there/p", outside = True)))
    asserts.equals(env, [], errors(_path_entry("@@//p", "/there/p"), outside))
    other = errors(outside, _path_entry("/there/q", "/there/q", outside = True))
    _contains(env, other[0], 'Package "p" is built from different directories', "/there/p", "/there/q")
    asserts.equals(env, 1, len(errors(_path_entry("@@//p", "/here/p"), outside)))

    # An entry shaped by another extension, without a location, is a different
    # directory from one outside.
    asserts.equals(env, 1, len(errors(struct(source = "path", directory = "@@//p", lock_label = "x"), outside)))
    return unittest.end(env)

def _absolute_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    for path, root, normalized in (
        ("/opt/./far/../pkg/", "/", "/opt/pkg"),
        ("/../pkg", "/", "/pkg"),
        ("C:\\work\\..\\pkg", "C:/", "C:/pkg"),
        ("c:/pkg", "c:/", "c:/pkg"),
        ("C:", "C:/", "C:/"),
        ("\\\\server\\share\\a\\..\\pkg", "//server/share/", "//server/share/pkg"),
        ("../../pkg", "", "../../pkg"),
        ("pkg", "", "pkg"),
        ("C:pkg", "", "C:pkg"),
    ):
        asserts.equals(env, root, pub_path_root(path), path)
        asserts.equals(env, normalized, normalize_pub_path(path), path)
    lock = Label("//app:pubspec.lock")
    for path, outside in (
        ("pkg", False),
        ("../pkg", False),
        ("..", False),
        ("../..", True),
        ("../../pkg", True),
        ("/opt/pkg", True),
        ("C:\\pkg", True),
        ("pkg/../../../up", True),
    ):
        asserts.equals(env, outside, pub_path_is_outside(lock, path), path)
    return unittest.end(env)

def _mapping_takes_plain_values_test_impl(ctx):
    # Another extension's tag has only to give the names.
    env = unittest.begin(ctx)
    lock = Label("//app/deep:pubspec.lock")
    packages = {"a": _path("../a"), "b": _path("../../../b"), "c": _path("/abs", relative = "False")}
    error = pub_lock_mapping_error("other_pub.from_lock(lock = x)", lock, packages)
    _contains(
        env,
        error,
        "other_pub.from_lock(lock = x):\n",
        '"a": "//app/a:<target>"',
        '"b": "//..."',
        '"c": "//..."',
    )
    asserts.equals(env, None, pub_lock_mapping_error("x", lock, packages, resolve = ["a"], build_from_pubspec = [], ignored = ["b", "c"]))
    asserts.equals(env, None, pub_lock_mapping_error("x", lock, packages, resolve = {"a": "//a"}, ignored = {"b": "why", "c": "why"}))
    return unittest.end(env)

def _fake_path(parts):
    return struct(
        parts = parts,
        dirname = _fake_path_above(parts),
        get_child = lambda child: _fake_path(parts + [child]),
    )

def _fake_path_above(parts):
    return struct(parts = parts[:-1], get_child = lambda child: _fake_path(parts[:-1] + [child]))

def _path_directory_test_impl(ctx):
    env = unittest.begin(ctx)

    def resolved(path):
        # The lock's directory is `repo/app`, deep enough for one step up.
        lock_file = struct(dirname = struct(
            parts = ["repo", "app"],
            dirname = struct(parts = ["repo"], get_child = lambda child: _fake_path(["repo", child])),
            get_child = lambda child: _fake_path(["repo", "app", child]),
        ))
        rctx = struct(path = lambda label: lock_file)
        return pub_lock_path_directory(rctx, Label("//app:pubspec.lock"), path).parts

    asserts.equals(env, ["repo", "app", "pkg"], resolved("pkg"))
    asserts.equals(env, ["repo", "app", "pkg"], resolved("./pkg/"))
    asserts.equals(env, ["repo", "sibling"], resolved("../sibling"))
    asserts.equals(env, ["repo", "sibling"], resolved("..\\sibling"))
    asserts.equals(env, ["repo", "app"], resolved("."))
    return unittest.end(env)

def _resolved_pubspecs_test_impl(ctx):
    env = unittest.begin(ctx)

    # A mapped package's pubspec is read where its first lock lists it, whether
    # or not that is inside the lock's repository.
    one = _lock(
        {
            "mine": _path("../mine/"),
            "abs": _path("/elsewhere/abs", relative = "false"),
            "outside": _path("../../outside"),
            "fork": _hosted(),
        },
        lock = "//app:pubspec.lock",
        resolve = {"mine": "//mine", "abs": "//abs", "outside": "//outside", "fork": "//fork"},
    )
    two = _lock({"mine": _path("../../elsewhere")}, lock = "//app/sub:pubspec.lock", resolve = {"mine": "//mine"})
    mapped = resolved_packages([one, two], {})
    asserts.equals(env, [], mapped.errors)
    found = resolved_pubspecs([one, two], mapped.targets)
    asserts.equals(env, ["abs", "mine", "outside"], sorted(found.keys()))
    asserts.equals(env, "/elsewhere/abs", found["abs"].path)
    asserts.equals(env, "../../outside", found["outside"].path)
    asserts.equals(env, "//mine", found["mine"].target)
    asserts.equals(env, "../mine", found["mine"].path)
    asserts.equals(env, Label("//app:pubspec.lock"), found["mine"].lock)
    asserts.equals(env, "0.1.0", found["mine"].version)
    return unittest.end(env)

def _published_here_test_impl(ctx):
    # rules_dart publishes `runfiles` to pub.dev from its own sources, so a
    # lock's pub.dev entry and rules_dart's target are one package. The lock's
    # version does not matter.
    env = unittest.begin(ctx)
    published = {"runfiles": "//dart/runfiles"}
    hosted = _lock({"runfiles": _hosted("0.1.0")})
    mapped = published_here_targets([hosted], {}, published)
    asserts.equals(env, "//dart/runfiles", mapped["runfiles"].target)

    # A build that names it nowhere gets no repository for it.
    asserts.equals(env, {}, published_here_targets([_lock({"a": _hosted()})], {}, published))

    # The user's own `resolve` wins.
    own = {"runfiles": struct(target = "//fork", lock_label = "//:pubspec.lock")}
    asserts.equals(env, "//fork", published_here_targets([hosted], own, published)["runfiles"].target)

    # What is not pub.dev's `runfiles` is some other package of that name.
    elsewhere = _hosted()
    elsewhere["description"] = {"sha256": "0" * 64, "url": "https://registry.example.invalid"}
    for other in (elsewhere, _git(), _path("third_party/runfiles")):
        asserts.equals(env, {}, published_here_targets([_lock({"runfiles": other})], {}, published))
        asserts.equals(env, {}, published_here_targets([hosted, _lock({"runfiles": other})], {}, published))

    # Older locks name pub.dev by its former host.
    legacy = _hosted()
    legacy["description"] = {"sha256": "0" * 64, "url": "https://pub.dartlang.org"}
    asserts.true(env, "runfiles" in published_here_targets([_lock({"runfiles": legacy})], {}, published))

    # What another pub extension reads, without this one's lock structure.
    listing = {"runfiles": _hosted("0.1.0")}
    asserts.equals(env, published, published_by_rules_dart([listing], published))
    asserts.equals(env, {}, published_by_rules_dart([], published))
    asserts.equals(env, {}, published_by_rules_dart([{"a": _hosted()}], published))
    asserts.equals(env, {}, published_by_rules_dart([listing, {"runfiles": _git()}], published))
    asserts.equals(env, {"runfiles": Label("//dart/runfiles")}, published_by_rules_dart([listing]))
    return unittest.end(env)

def _published_declaration_test_impl(ctx):
    # A `pub.package()` states a version and a digest. For a package rules_dart
    # publishes neither would be honoured, so stating them is refused.
    env = unittest.begin(ctx)
    errors = published_declaration_errors({"runfiles": ["the root module", "module `dep`"], "http": ["the root module"]})
    asserts.equals(env, 1, len(errors), str(errors))
    _contains(
        env,
        errors[0],
        '`pub.package(name = "runfiles")`',
        "the root module, module `dep`",
        "@rules_dart//dart/runfiles",
        "Remove the declaration",
    )
    asserts.equals(env, [], published_declaration_errors({"http": ["the root module"]}))
    return unittest.end(env)

_t0_test = unittest.make(_pub_command_test_impl)
_t1_test = unittest.make(_mapping_accepts_every_path_package_named_once_test_impl)
_t2_test = unittest.make(_mapping_names_each_problem_test_impl)
_t3_test = unittest.make(_resolve_agreement_test_impl)
_t4_test = unittest.make(_path_agreement_test_impl)
_t5_test = unittest.make(_git_entry_pinned_test_impl)
_t6_test = unittest.make(_git_entry_unpinned_test_impl)
_t7_test = unittest.make(_git_disagreement_test_impl)
_t8_test = unittest.make(_source_disagreement_test_impl)
_t9_test = unittest.make(_resolved_pubspecs_test_impl)
_t10_test = unittest.make(_published_here_test_impl)
_t11_test = unittest.make(_published_declaration_test_impl)
_t12_test = unittest.make(_git_agreement_is_identity_test_impl)
_t13_test = unittest.make(_entries_test_impl)
_t14_test = unittest.make(_mapping_takes_plain_values_test_impl)
_t15_test = unittest.make(_path_directory_test_impl)
_t16_test = unittest.make(_path_disagreement_test_impl)
_t17_test = unittest.make(_absolute_paths_test_impl)

def pub_lock_checks_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test, _t10_test, _t11_test, _t12_test, _t13_test, _t14_test, _t15_test, _t16_test, _t17_test)
