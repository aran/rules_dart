# How to Contribute

## Using devcontainers

If you are using [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers)
and/or [codespaces](https://github.com/features/codespaces), the container
installs prek and the git hooks on start. It does not build `.bazel_env`, which
most hooks run from: run the `@overhead//:bazel_env` command in the next
section once the container is up.

## Formatting

Starlark files must be formatted by buildifier, and YAML files by yamlfmt.
Git hooks check this, along with prettier, typos, file hygiene and the commit
message policy. They run with [prek](https://github.com/j178/prek), which reads
`.pre-commit-config.yaml`. Install prek with [uv](https://docs.astral.sh/uv/)
and set up the hooks once per clone:

```shell
uv tool install prek
prek install -f
```

`-f` replaces hooks already in the clone, such as ones pre-commit installed;
without it prek keeps them and runs them too. The installed hook calls the prek at `~/.local/bin/prek`, which stays put across
`uv tool upgrade prek` and `bazel clean`. Set `PREK_QUIET=1` in your shell
profile for hooks that print nothing unless one fails.

The commit message, buildifier, yamlfmt, typos and actionlint hooks run overhead's tools from
`.bazel_env/bin`, without Bazel. Set that up in the main checkout, and again
after any `bazel clean` or bump of overhead's pin:

```shell
bazel run --noincompatible_auto_exec_groups @overhead//:bazel_env
```

A hook that fails with "No such file or directory" means it is not set up.
The flag is there because bazel_env 0.10.0 fails analysis under
`--incompatible_auto_exec_groups`, which `.bazelrc` sets; it costs the next
build a re-analysis, not a rebuild.

A worktree made with `git worktree add` needs it too: run the command above in
the worktree, or link its `.bazel_env` to the main checkout's.

To run every hook over every file, as CI does:

```shell
prek run --all-files
```

On Windows, where bazel_env does not run, install the hooks without the six
that need it:

```shell
prek install -f --skip commit-message --skip buildifier --skip buildifier-lint --skip yamlfmt --skip typos --skip actionlint
```

and before you push, run every check with the tools through `bazel run`
instead. `--enable_runfiles` is needed by the Windows launchers of the pinned
tools:

```shell
bazel run --enable_runfiles @overhead//lint:prek -- run --all-files --hook-stage manual
```

The manual stage has no commit-message check; check the commits you are about
to push with

```shell
bazel run --enable_runfiles @overhead//changelog:check -- --range origin/main..HEAD
```

## Commit messages

Commits follow the conventional-commit format and the `Changelog:` trailer
policy in [AGENTS.md](AGENTS.md#changelog). CI checks every push to `main`;
the commit-msg hook that `prek install` sets up checks each commit before that.

## Running tests

### Unit tests (root workspace)

```shell
bazel test //...
```

The Gazelle plugin is the `rules_dart_gazelle_plugin` module in `gazelle/`,
which `//...` does not reach. Its tests run from the root workspace,
`bazel test @rules_dart_gazelle_plugin//... @rules_dart_dev//...`, and its
generation tests are also in `e2e/examples/gazelle`. There Gazelle writes the
BUILD files of `codegen/`, `cycle/`, `rally/` and `split/`, which that
workspace builds and tests; run `bazel run //gazelle:gazelle -- gazelle` in
`e2e/examples` after changing the plugin, and CI fails when it would change a
BUILD file.

### End-to-end tests (separate Bazel workspaces)

The workspaces under `e2e/` use rules_dart as an external dependency:

```shell
# The install instructions, as the Bazel Central Registry checks them
cd e2e/smoke && bazel test //...

# One example per feature, and fixtures/ for their edge cases
cd e2e/examples && bazel test //...

# Fixtures that need a root-level setting e2e/examples cannot share
cd e2e/root_settings && bazel test //...
```

Each workspace under `e2e/failures` must fail to resolve; CI's
`expected-failure` job runs each and checks the error. Fixtures elsewhere that
must fail are `manual`, and the same job builds each by name.

## Updating BUILD files

Gazelle writes the `bzl_library` targets, and only those.
Run `bazel run @rules_dart_dev//:gazelle` to keep them up-to-date; CI fails when
it would change a BUILD file. It writes a new target's `deps` but leaves an
existing target's alone, so a `load()` added to a file needs its `deps` entry
by hand. For a public file, its API docs extraction fails the build without it,
and `docs_test` in its package fails when a public symbol has no doc.

## Using this as a development dependency of other rules

You'll commonly find that you develop in another repository that
depends on rules_dart.

To tell Bazel to use this local checkout rather than a release artifact or a
version fetched from the registry, put an override in the other repository's
gitignored `.bazelrc.user` (its `.bazelrc` ends with
`try-import %workspace%/.bazelrc.user`), running this from this directory:

```sh
echo "common --override_module=rules_dart=$(pwd)" >> <other repository>/.bazelrc.user
```

The lock tools leave `.bazelrc.user` out, so the override never reaches a
committed `MODULE.bazel.lock`. Do not put it in `~/.bazelrc`: every Bazel
command on the machine reads that file, lock refreshes included.

## Releasing

Releases are automated on a cron trigger.
The new version is determined automatically from the commit history, assuming the commit messages follow conventions, using
https://github.com/marketplace/actions/conventional-commits-versioner-action.
If you do nothing, eventually the newest commits will be released automatically as a patch or minor release.
This automation is defined in .github/workflows/tag.yaml.
A scheduled run tags at most once per two weeks, and only a commit on which
CI passed. When the next version is a major, the automation tags it but does
not release it, so tag a major by hand, as below, before the automation does.

Rather than wait for the cron event, you can trigger manually. Navigate to
https://github.com/aran/rules_dart/actions/workflows/tag.yaml
and press the "Run workflow" button. A dispatched run tags whenever there is
something to release, still only a commit on which CI passed.

If you need control over the next release version, for example when making a release candidate for a new major,
then: tag the repo and push the tag, for example

```sh
% git fetch
% git tag -s -m "rules_dart v1.0.0-rc0" v1.0.0-rc0 origin/main
% git push origin v1.0.0-rc0
```

Then watch the automation run on GitHub actions which creates the release.

The release opens its Bazel Central Registry pull request as a draft; mark it
ready for review, which starts BCR's checks and auto-approval. If the
publishing step failed, `.github/workflows/publish.yaml` reruns it for a tag.
