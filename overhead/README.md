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
checkout root: `check-commit-messages`, `typos`, `yamlfmt` and `dart`.
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
- repeats the pre-commit ones in the `manual` stage through `bazel run`
  (`@overhead//lint:typos`, `@overhead//lint:yamlfmt`), with
  `default_stages: [pre-commit, manual]`, so that CI and Windows, where
  bazel_env does not run, check the same files without it:
  `bazel run @overhead//lint:prek -- run --all-files --hook-stage manual`.

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
