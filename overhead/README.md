# overhead

Development tooling shared by rules_dart, rules_dart_proto, rules_flutter and
frustrate: the commit policy, release notes, tool pins, lock checks, CI
workflow check, bazelrc preset, commit hooks and test VMs. Its reusable workflows are in rules_dart's `.github/workflows`, each
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
and `actionlint`. None downloads anything when a hook runs:
`buildifier`, `typos` and `yamlfmt` are pinned in `multitool.lock.json`;
`check-commit-messages` and `actionlint` (which runs the pinned actionlint with
the pinned shellcheck) are overhead's own `dart_binary`s.
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
bazel run @overhead//locks:check                            # check
bazel run --lockfile_mode=off @overhead//locks:refresh      # rewrite
```

The tool is built in the root workspace, so a refresh builds it with
`--lockfile_mode=off`: a stale root lock cannot stop it, and `--override_module`
flags in `.bazelrc.user` cannot leak into the root lock, which the tool then
rewrites itself. A check needs no flag.
`locks/locks_cli.dart` says more.

## CI workflow

```shell
bazel run @overhead//ci:check
```

checks `.github/workflows/ci.yaml` against the repository: a `conclusion` job,
the one branch protection requires, needs every job but those with
`continue-on-error: true`, and none of those; and some job runs in every
workspace the lock check knows. A job runs in each folder of its `folders`
input (bazel-contrib's `bazel.yaml`) and in each of its steps' directories:
`working-directory`, or for a `run` step the job's or the workflow's
`defaults.run.working-directory`, with `${{ matrix.<key> }}` expanded over a
matrix the file lists. A directory it cannot read, such as a matrix computed by
another job, is an error. A repository's own tools that mirror CI read the
workflow through the `@overhead//ci` library (`ci/lib/ci_workflow.dart`), as
rules_dart's `tools/vm` does.

## Bazelrc preset

The flags [bazelrc-preset.bzl](https://github.com/bazel-contrib/bazelrc-preset.bzl)
recommends, at the version overhead pins and for the Bazel the repository
runs, are written to `tools/preset.bazelrc`, which the root `.bazelrc` imports
first:

```shell
bazel run @overhead//preset              # write tools/preset.bazelrc
bazel run @overhead//preset -- --check   # fail if it is out of date
```

```
import %workspace%/tools/preset.bazelrc
```

The file is checked in. Bumping overhead's pin or the repository's
`.bazelversion` can change it, so CI runs the check, and a bump runs the tool.
A repository takes no `bazel_dep` on bazelrc-preset.bzl of its own.

## Test VMs

Throwaway SPOT VMs on Google Cloud, to run a repository's e2e suites on Linux
or Windows, from `gcloud`'s project and zone (`CLOUDSDK_COMPUTE_ZONE` wins):

```shell
bazel run @overhead//vm:create_linux_vm -- <vm-name> [--machine-type=..] [--disk-size=..]
bazel run @overhead//vm:create_windows_vm -- <vm-name> [--machine-type=..] [--disk-size=..]
gcloud compute instances delete <vm-name> --quiet
```

Each has a C/C++ toolchain, git and bazelisk, and returns once the VM's
startup script has finished. A repository that needs more on its VMs calls
`createLinuxVm` or `createWindowsVm` (`vm/lib/create_vm.dart`) from a
`dart_binary` of its own, with its packages and startup steps.

What runs on a VM is the repository's to say: its own `dart_binary`, over
`@overhead//vm`, passes `runE2e` (`vm/lib/e2e.dart`) a list of `E2eItem`s,
each Bazel or a script in a folder with the exit codes that pass, read from
whatever says what its CI runs; and, if it needs them, setup steps and
options of its own. The runner copies the committed HEAD over, writes the
VM's home bazelrc (one disk cache, idle exit, heap cap, `--keep_going`, and
with `--remote-cache=<url>` a cache the VMs share), runs the items, and
summarises. rules_dart's `tools/vm` is the example.
