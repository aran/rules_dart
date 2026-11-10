# overhead

Development tooling shared by rules_dart, rules_dart_proto, rules_flutter and
frustrate: the commit policy, release notes, tool pins, lock checks and commit
hooks. Its reusable workflows are in rules_dart's `.github/workflows`, each
with its use in its header.

## Taking it

A repository takes overhead as a dev dependency, pinned to a rules_dart
commit, and calls the reusable workflows at that same commit
(`bazel run @overhead//pins:check` refuses two revisions):

```starlark
bazel_dep(name = "overhead", version = "0.0.0", dev_dependency = True)
git_override(
    module_name = "overhead",
    commit = "<sha>",
    remote = "https://github.com/aran/rules_dart.git",
    strip_prefix = "overhead",
)
```

Every tool runs from the repository's checkout root, with `bazel run`.

## Commit hooks

The hooks run overhead's tools without Bazel, from `.bazel_env/bin` in the
checkout root: `check-commit-messages`, `buildifier`, `typos`, `yamlfmt`,
`actionlint` and `dart`. None downloads anything when a hook runs: each is pinned
in `multitool.lock.json`.
`//:bazel_env` builds them there:

```shell
bazel run --noincompatible_auto_exec_groups @overhead//:bazel_env
```

Run it in the main checkout, after a `bazel clean`, and after bumping
overhead's pin; until then the hooks run the old tools. A worktree made by
hand (`git worktree add`) runs it too. A hook that fails with "No such file
or directory" means it has not been run. The flag is needed because bazel_env
0.10.0 fails analysis under `--incompatible_auto_exec_groups`; it makes the
next ordinary build re-analyse, not rebuild.

In `.pre-commit-config.yaml`, a repository:

- calls `.bazel_env/bin/<tool>` from local hooks in the `pre-commit` and
  `commit-msg` stages, and puts `.bazel_env` in `.gitignore`;
- repeats the pre-commit ones in the `manual` stage through
  `bazel run --enable_runfiles` (`@overhead//lint:buildifier`,
  `@overhead//lint:typos`, `@overhead//lint:yamlfmt`, `@overhead//lint:actionlint`), with
  `default_stages: [pre-commit, manual]`, so that Windows, where bazel_env
  does not run, checks the same files without it. The flag is there because
  the Windows launchers of the tools pinned in `multitool.lock.json` need a
  runfiles tree, which Windows does not make by default:

  ```shell
  bazel run --enable_runfiles @overhead//lint:prek -- run --all-files --hook-stage manual
  ```

  The manual hooks take 20 files per command (`pass_filenames: 20`): the
  launchers are `.bat` files, which cmd.exe limits to 8191 characters, and prek
  would otherwise batch to the operating system's 32k.

  Git for Windows checks files out with CRLF unless the repository says
  otherwise, and yamlfmt rewrites them to LF. A consumer needs
  `* text=auto eol=lf` in its `.gitattributes`, so that every checkout is LF.

CI builds the tools once and runs the hooks as a commit does, rather than the
manual stage, which starts a Bazel client per hook and batch of files:

```shell
bazel run --noincompatible_auto_exec_groups @overhead//:bazel_env -- update-symlink
bazel run --noincompatible_auto_exec_groups @overhead//lint:prek -- run --all-files
```

`update-symlink` builds `.bazel_env` without the setup report, which exits
non-zero where the tools are not on `PATH`.

rules_dart's `.pre-commit-config.yaml` is the example.

## Lock files

```shell
bazel run @overhead//locks                                    # check
bazel run --lockfile_mode=off @overhead//locks -- --refresh   # rewrite
```

The tool is built in the root workspace, so a refresh builds it with
`--lockfile_mode=off`: a stale root lock cannot stop it, and `--override_module`
flags in `.bazelrc.user` cannot leak into the root lock, which the tool then
rewrites itself. A check needs no flag.
`locks/locks.dart` says more.
