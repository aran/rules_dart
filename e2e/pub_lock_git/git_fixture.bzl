"""Makes the git repositories this workspace's packages come from, and their lock.

Two remotes, each a repository `dart pub get` could resolve against:

- `remote.git`, a bare repository holding three packages in subdirectories.
  `git_sub` is locked at its first commit, which is no longer a branch tip.
  Its text files carry attributes, from its own `.gitattributes` and from the
  repository root's; one is stored with CRLF; and of its two symlinks, one
  leaves the package. `git_cyc_a` and `git_cyc_b` depend on each other.
- `root.git`, a bare repository holding `git_root` at its root, locked at a
  commit that is no branch tip.

The lock names both by paths relative to itself, as pub writes a repository
a pubspec names by a relative path. With `PUB_LOCK_GIT_REMOTES` set, to a
directory, the remotes are made there instead and the lock names them
`ssh://git-fixture.invalid/<name>.git`, a host that does not exist: they are
reachable only through settings the client's environment gives git
(`GIT_CONFIG_COUNT`, `GIT_SSH_COMMAND`), which `check_host_config.dart` sets.
Commits are made with fixed authors and
dates and none of the host's git configuration, so their ids are the same on
every machine; `commits.bzl` names them.
"""

_ENV = {
    "GIT_AUTHOR_NAME": "fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
    "GIT_COMMITTER_NAME": "fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
    "GIT_CONFIG_NOSYSTEM": "1",
}

def _git(rctx, env, work, *args):
    result = rctx.execute([rctx.which("git"), "-C", str(work)] + list(args), environment = env)
    if result.return_code != 0:
        fail("git {} in {}: {}{}".format(args, work, result.stdout, result.stderr))
    return result.stdout.strip()

def _commit(rctx, env, work, message, links = {}):
    _git(rctx, env, work, "add", "-A")

    # Symlinks go in as git stores them, by their target's text, so the
    # fixture makes the same commits on a host that cannot make links.
    for path, target in links.items():
        target_file = str(work) + ".link"
        rctx.file(target_file, target, executable = False)
        blob = _git(rctx, env, work, "hash-object", "-w", target_file)
        _git(rctx, env, work, "update-index", "--add", "--cacheinfo", "120000,{},{}".format(blob, path))
        rctx.delete(target_file)
    _git(rctx, env, work, "commit", "-q", "--no-verify", "-m", message)
    return _git(rctx, env, work, "rev-parse", "HEAD")

def _repo(rctx, env, name):
    work = rctx.path("_work/" + name)
    rctx.file(str(work) + "/.keep", "", executable = False)
    _git(rctx, env, work, "init", "-q", "--template=")
    _git(rctx, env, work, "symbolic-ref", "HEAD", "refs/heads/main")
    rctx.delete(str(work) + "/.keep")
    return work

def _remote(rctx, env, remotes, work, name):
    where = remotes + "/" + name if remotes else name
    rctx.delete(where)
    _git(rctx, env, rctx.path("."), "clone", "-q", "--bare", "--template=", str(work), where)

def _pubspec(name, deps = []):
    text = "name: {}\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n".format(name)
    if deps:
        text += "dependencies:\n" + "".join(["  {}: any\n".format(d) for d in deps])
    return text

def _lock_entry(name, url, ref, path):
    return """\
  {name}:
    dependency: "direct main"
    description:
      path: "{path}"
      ref: main
      resolved-ref: "{ref}"
      url: "{url}"
    source: git
    version: "1.0.0"
""".format(name = name, url = url, ref = ref, path = path)

def _impl(rctx):
    remotes = rctx.getenv("PUB_LOCK_GIT_REMOTES")
    home = rctx.path("_home")
    rctx.file("_home/.keep", "", executable = False)
    env = dict(_ENV)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home)
    for var in rctx.os.environ:
        if var.upper().startswith("GIT_") and var not in env:
            env[var] = None

    def put(work, path, content):
        rctx.file(str(work) + "/" + path, content, executable = False)

    # The monorepo, served as a bare repository.
    mono = _repo(rctx, env, "mono")
    put(mono, ".gitattributes", "pkgs/sub/lib/root_attr.txt eol=crlf\n")
    put(mono, "other/outside.txt", "outside\n")
    put(mono, "pkgs/sub/pubspec.yaml", _pubspec("git_sub"))
    put(mono, "pkgs/sub/.gitattributes", "lib/crlf.txt eol=crlf\nlib/blob_crlf.txt -text\n")
    put(mono, "pkgs/sub/lib/git_sub.dart", "String revision() => 'v1';\n")
    put(mono, "pkgs/sub/lib/crlf.txt", "x\ny\n")
    put(mono, "pkgs/sub/lib/root_attr.txt", "x\ny\n")
    put(mono, "pkgs/sub/lib/blob_crlf.txt", "x\r\ny\r\n")
    put(mono, "pkgs/sub/lib/plain.txt", "x\ny\n")
    links = {
        # Inside the package: kept.
        "pkgs/sub/lib/plain_link.txt": "plain.txt",
        # Out of the package, which is served without the rest of the
        # repository: dropped.
        "pkgs/sub/lib/escape.txt": "../../../other/outside.txt",
    }
    put(mono, "pkgs/cyc_a/pubspec.yaml", _pubspec("git_cyc_a", ["git_cyc_b"]))
    put(mono, "pkgs/cyc_a/lib/git_cyc_a.dart", "import 'package:git_cyc_b/git_cyc_b.dart';\n\nString a() => 'a';\nString viaB() => b();\n")
    put(mono, "pkgs/cyc_b/pubspec.yaml", _pubspec("git_cyc_b", ["git_cyc_a"]))
    put(mono, "pkgs/cyc_b/lib/git_cyc_b.dart", "import 'package:git_cyc_a/git_cyc_a.dart';\n\nString b() => 'b';\nString viaA() => a();\n")

    # License files: the repository's own, outside every package, is none of
    # theirs; `license` is not `LICENSE`, even on a disk that cannot tell them
    # apart; and a directory named `NOTICES` is not a file.
    put(mono, "LICENSE", "repository\n")
    put(mono, "pkgs/sub/LICENSE", "git_sub\n")
    put(mono, "pkgs/cyc_a/license", "git_cyc_a\n")
    put(mono, "pkgs/cyc_b/NOTICES/README", "git_cyc_b\n")
    sub_v1 = _commit(rctx, env, mono, "v1", links)
    put(mono, "pkgs/sub/lib/git_sub.dart", "String revision() => 'v2';\n")
    mono_v2 = _commit(rctx, env, mono, "v2", links)
    _remote(rctx, env, remotes, mono, "remote.git")

    # A package at the root of its repository.
    single = _repo(rctx, env, "single")
    put(single, "pubspec.yaml", _pubspec("git_root"))
    put(single, "lib/git_root.dart", "String revision() => 'r1';\n")
    put(single, "LICENSE", "git_root license\n")
    put(single, "NOTICES", "git_root notices\n")
    root_r1 = _commit(rctx, env, single, "r1")
    put(single, "lib/git_root.dart", "String revision() => 'r2';\n")
    _commit(rctx, env, single, "r2")
    _remote(rctx, env, remotes, single, "root.git")

    rctx.delete("_work")
    rctx.delete("_home")
    where = ("ssh://git-fixture.invalid/" if remotes else "")
    rctx.file("pubspec.lock", "packages:\n" + "".join([
        _lock_entry("git_root", where + "root.git", root_r1, "."),
        _lock_entry("git_cyc_a", where + "remote.git", mono_v2, "pkgs/cyc_a"),
        _lock_entry("git_cyc_b", where + "remote.git", mono_v2, "pkgs/cyc_b"),
        _lock_entry("git_sub", where + "remote.git", sub_v1, "pkgs/sub"),
    ]) + "sdks:\n  dart: \">=3.0.0 <4.0.0\"\n", executable = False)
    rctx.file("BUILD.bazel", 'exports_files(["pubspec.lock"])\n', executable = False)

    # The commits the lock pins, for checks that name them.
    rctx.file("commits.bzl", "COMMITS = %s\n" % json.encode({
        "mono_v2": mono_v2,
        "root_r1": root_r1,
        "sub_v1": sub_v1,
    }), executable = False)

git_fixture = repository_rule(implementation = _impl)
