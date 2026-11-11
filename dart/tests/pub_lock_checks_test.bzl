"""Unit tests for dart/pub/private/pub_lock_checks.bzl.

The `pub` extension refuses a lock whose mapping of its packages is wrong,
locks that disagree on what serves a package, and a git entry that pins
nothing. Each check returns its messages, so the extension can report every
refusal of a phase at once.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load(
    "//dart/pub/private:pub_lock_checks.bzl",
    "git_disagreement_error",
    "git_lock_package",
    "lock_mapping_error",
    "path_packages",
    "pub_command",
    "resolved_packages",
    "resolved_pubspecs",
    "source_disagreement_errors",
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
        'build_from_pubspec = ["models"]',
        "`build_from_pubspec` names `far` (/opt/far), whose directory the lock gives by an absolute path",
        "`build_from_pubspec` names `outside` (../../outside), whose directory is outside the repository",
    )
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

    agreed = path_packages([one], {}, {})
    asserts.equals(env, [], agreed.errors)
    asserts.equals(env, "@@//one/m", agreed.built["m"].directory)

    refused = path_packages([one, two, r], {"d": []}, resolved_packages([r], {}).targets)
    _contains(env, "\n".join(refused.errors), "Package \"d\" is declared with `pub.package()` and named by the `pub.from_lock()` for @@//two:pubspec.lock")
    _contains(env, "\n".join(refused.errors), "Package \"m\" is built from different directories:", "  - @@//one/m (by", "  - @@//elsewhere/m (by")
    _contains(env, "\n".join(refused.errors), "Package \"i\" is built from its pubspec by the `pub.from_lock()` for @@//one:pubspec.lock and ignored by the one for @@//two:pubspec.lock")
    _contains(env, "\n".join(refused.errors), "Package \"m\" is mapped by `resolve` in the `pub.from_lock()` for @@//r:pubspec.lock")
    return unittest.end(env)

def _git_entry_pinned_test_impl(ctx):
    env = unittest.begin(ctx)
    tag = _tag("//app:pubspec.lock")
    read = git_lock_package("foo", _git(), tag)
    asserts.equals(env, [], read.errors)
    asserts.equals(env, _COMMIT_A, read.package.resolved_ref)
    asserts.equals(env, None, read.package.lock, "an absolute url names no lock")

    relative = git_lock_package("foo", _git(url = "../foo"), tag)
    asserts.equals(env, Label("//app:pubspec.lock"), relative.package.lock, "a relative url is resolved against the lock")
    return unittest.end(env)

def _git_entry_unpinned_test_impl(ctx):
    env = unittest.begin(ctx)
    tag = _tag("//app:pubspec.lock")
    short = git_lock_package("foo", _git(ref = "a1b2c3d"), tag)
    asserts.equals(env, None, short.package)
    asserts.equals(env, 1, len(short.errors))
    _contains(
        env,
        short.errors[0],
        'resolved-ref "a1b2c3d", which is not a full commit id',
        "bazel run @rules_dart//dart/pub -- get --directory=app",
    )

    neither = git_lock_package("foo", _git(url = "", ref = None), tag)
    asserts.equals(env, None, neither.package)
    asserts.equals(env, 2, len(neither.errors), "a missing url and a missing commit are each named")
    _contains(env, neither.errors[0], 'The git package "foo" 1.0.0 (in @@//app:pubspec.lock) has no `description.url`.')
    _contains(env, neither.errors[1], 'resolved-ref "", which is not a full commit id')
    return unittest.end(env)

def _git_disagreement_test_impl(ctx):
    env = unittest.begin(ctx)
    one = git_lock_package("foo", _git(), _tag("//one:pubspec.lock")).package
    same = git_lock_package("foo", _git(), _tag("//same:pubspec.lock")).package
    other = git_lock_package("foo", _git(ref = _COMMIT_B), _tag("//two:pubspec.lock")).package
    subdir = git_lock_package("foo", _git(path = "pkgs/foo"), _tag("//sub:pubspec.lock")).package

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
    rel_one = git_lock_package("foo", _git(url = "../foo"), _tag("//one:pubspec.lock")).package
    rel_two = git_lock_package("foo", _git(url = "../foo"), _tag("//two:pubspec.lock")).package
    asserts.true(env, git_disagreement_error("foo", rel_one, rel_two) != None, "one relative url from two directories")
    return unittest.end(env)

def _source_disagreement_test_impl(ctx):
    env = unittest.begin(ctx)
    git = {
        "foo": git_lock_package("foo", _git(), _tag("//one:pubspec.lock")).package,
        "bar": git_lock_package("bar", _git(), _tag("//one:pubspec.lock")).package,
    }
    hosted = {
        "foo": [struct(lock_label = "@@//two:pubspec.lock")],
        "baz": [struct(lock_label = "@@//two:pubspec.lock")],
    }
    built = {
        "bar": struct(directory = "@@//bar", lock_label = "@@//three:pubspec.lock"),
        "baz": struct(directory = "@@//baz", lock_label = "@@//three:pubspec.lock"),
        "alone": struct(directory = "@@//alone", lock_label = "@@//three:pubspec.lock"),
    }
    errors = "\n".join(source_disagreement_errors(built, git, hosted))
    _contains(
        env,
        errors,
        "Package \"foo\" is a git package in @@//one:pubspec.lock and a hosted package in @@//two:pubspec.lock.",
        "Package \"bar\" is built from @@//bar by the `pub.from_lock()` for @@//three:pubspec.lock, and another lock lists it as a git package.",
        "Package \"baz\" is built from @@//baz by the `pub.from_lock()` for @@//three:pubspec.lock, and another lock lists it as a hosted package.",
    )
    asserts.false(env, "alone" in errors, "a package one source serves agrees")
    asserts.equals(env, [], source_disagreement_errors({}, {"bar": git["bar"]}, {"baz": hosted["baz"]}))
    return unittest.end(env)

def _resolved_pubspecs_test_impl(ctx):
    env = unittest.begin(ctx)

    # A mapped package's pubspec is read where its lock lists it by a relative
    # path inside the lock's repository, from the first such lock.
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
    asserts.equals(env, ["mine"], found.keys())
    asserts.equals(env, "//mine", found["mine"].target)
    asserts.equals(env, "../mine", found["mine"].path)
    asserts.equals(env, Label("//app:pubspec.lock"), found["mine"].lock)
    asserts.equals(env, "0.1.0", found["mine"].version)
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

def pub_lock_checks_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test)
