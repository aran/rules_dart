Run a read-only audit of all maintenance chores. Do NOT make any changes — only report findings.

## Instructions

1. Read `docs/CHORES.md` for the full chore list.

2. For each chore, check current state:

   **Dart SDK**: Fetch `https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION` to find the latest stable version. Compare against the first key in `dart/private/versions.bzl`.

   **Bazel**: Check the latest release at `https://github.com/bazelbuild/bazel/releases/latest`. Compare against `.bazelversion`.

   **bazel_dep versions**: For the key deps (`bazel_skylib`, `platforms`, `gazelle`, `rules_go`, `package_metadata`), check latest versions on BCR at `https://registry.bazel.build/modules/{name}`. Compare against root `MODULE.bazel`.

   **CI folder list sync**: Glob `e2e/*/MODULE.bazel` to find all e2e workspaces. Read `.github/workflows/ci.yaml` and compare its `folders` array. Report any workspaces missing from CI or CI entries for non-existent workspaces.

   **Documentation accuracy**: Read `docs/ARCHITECTURE.md` and check:

   - Does the directory tree match actual files? (spot check)
   - Does the e2e list in the testing table match actual `e2e/` directories?
   - Are version strings current?

   **GitHub workflow dependencies**: Grep all `.github/workflows/*.yaml` files for `uses:` lines. For each external dependency (actions and reusable workflows), check the repo's latest release/tag via `gh api repos/{owner}/{repo}/releases/latest` or `gh api repos/{owner}/{repo}/tags`. Report any that are outdated. Also flag inconsistencies (e.g. `actions/checkout` pinned to different versions across workflows).

   **Multitool versions**: Follow `docs/CHORES.md` § "Multitool Version Bumps" to check for outdated tools.

   **Pre-commit config sync**: Compare the `rev:` values for yamlfmt and typos in `.pre-commit-config.yaml` against the versions in `multitool.lock.json`. They should match (per `docs/CHORES.md` § "Multitool Version Bumps").

   **Pre-commit hooks**: Run `pre-commit autoupdate --dry-run` if pre-commit is available. Report if any hooks are outdated.

   **In-repo Dart packages**: For each `pubspec.yaml` under `dart/` (currently `dart/runfiles/pubspec.yaml`):

   - Read the `environment.sdk` lower bound and compare against the project's minimum supported Dart SDK (from `dart/private/versions.bzl`). They should be consistent.
   - Run `dart pub outdated` in the package directory and report any outdated dependencies.

3. Present findings as a checklist:

   ```
   - [x] Dart SDK: current (3.11.0)
   - [ ] Bazel: stale (have 8.2.1, latest is 8.3.0) → /bump-bazel 8.3.0
   - [x] bazel_dep versions: all current
   - [x] Multitool: all current
   ...
   ```

   For each stale item, suggest the specific action or slash command to fix it.
