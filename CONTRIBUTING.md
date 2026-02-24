# How to Contribute

## Using devcontainers

If you are using [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers)
and/or [codespaces](https://github.com/features/codespaces) then you can start
contributing immediately and skip the next step.

## Formatting

Starlark files should be formatted by buildifier.
We suggest using a pre-commit hook to automate this.
First [install pre-commit](https://pre-commit.com/#installation),
then run

```shell
pre-commit install
```

Otherwise later tooling on CI will yell at you about formatting/linting violations.

## Running tests

### Unit tests and Gazelle plugin tests (root workspace)

```shell
bazel test //dart/tests:versions_test //dev:gazelle_test //dev:gazelle_generation_test
```

### End-to-end tests (separate Bazel workspaces)

Each directory under `e2e/` is a self-contained Bazel workspace that tests rules_dart
as an external dependency. Some contain `bazel test` targets, others verify that
`bazel build` succeeds.

```shell
# Toolchain resolution
cd e2e/smoke && bazel test //...

# dart_binary (native executable compilation)
cd e2e/hello_world && bazel build //...

# Transitive dart_library dependencies
cd e2e/library_deps && bazel build //...

# dart_analyze_test and dart_format_test
cd e2e/analysis && bazel test //...

# dart_test (Dart VM test execution)
cd e2e/dart_test && bazel test //...

# External pub.dev packages
cd e2e/pub_deps && bazel build //...

# pubspec.lock integration
cd e2e/pub_lock && bazel build //...

# dart compile js (web compilation)
cd e2e/web_app && bazel build //...
```

## Updating BUILD files

Some targets are generated from sources.
Currently this is just the `bzl_library` targets.
Run `bazel run //:gazelle` to keep them up-to-date.

## Using this as a development dependency of other rules

You'll commonly find that you develop in another repository that
depends on rules_dart.

To always tell Bazel to use this local checkout rather than a release
artifact or a version fetched from the registry, run this from this
directory:

```sh
OVERRIDE="--override_module=rules_dart=$(pwd)"
echo "common $OVERRIDE" >> ~/.bazelrc
```

This means that any usage of `@rules_dart` on your system will point to this folder.

## Releasing

Releases are automated on a cron trigger.
The new version is determined automatically from the commit history, assuming the commit messages follow conventions, using
https://github.com/marketplace/actions/conventional-commits-versioner-action.
If you do nothing, eventually the newest commits will be released automatically as a patch or minor release.
This automation is defined in .github/workflows/tag.yaml.

Rather than wait for the cron event, you can trigger manually. Navigate to
https://github.com/aran/rules_dart/actions/workflows/tag.yaml
and press the "Run workflow" button.

If you need control over the next release version, for example when making a release candidate for a new major,
then: tag the repo and push the tag, for example

```sh
% git fetch
% git tag v1.0.0-rc0 origin/main
% git push origin v1.0.0-rc0
```

Then watch the automation run on GitHub actions which creates the release.
