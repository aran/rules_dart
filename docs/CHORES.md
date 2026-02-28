# Maintenance Chores

Central reference for all recurring maintenance tasks. Slash commands read this
file at runtime — keep file lists current as the repo evolves.

---

## Dart SDK Version Bump

**Trigger**: New stable Dart SDK release.

**Files**:

- `dart/private/versions.bzl` — add new version entry to `TOOL_VERSIONS`
- `MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/hello_world/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/library_deps/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/dart_test/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/analysis/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/web_app/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/pub_deps/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/pub_lock/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/gazelle/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/cross_compile/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `README.md` — `dart.toolchain(dart_version = "...")` in installation snippet
- `docs/ARCHITECTURE.md` — `dart.toolchain(dart_version = "...")` in directory tree
- `dart/tests/versions_test.bzl` — asserted version key in `_smoke_test_impl`
- `dart/runfiles/pubspec.yaml` — `environment.sdk` constraint

**Procedure**:

1. Run `dart run tool/fetch_sdk_hashes.dart {version}` to get SHA-256 hashes
2. Add the new version entry to `dart/private/versions.bzl`
3. Update `dart_version` in all MODULE.bazel files listed above
4. Update version references in `README.md` and `docs/ARCHITECTURE.md`
5. Update `dart/tests/versions_test.bzl` (asserted version key)
6. Regenerate lock files: `dart run tool/refresh_locks.dart`
7. Run `bazel test //dart/tests/...` to verify unit tests pass
8. Pick one e2e workspace and run `bazel build //...` to smoke-test

**Verification**: `bazel test //dart/tests/...` passes; at least one e2e workspace builds.

**Automation**: `/bump-dart-sdk {version}` slash command.

---

## Bazel Version Bump

**Trigger**: New Bazel release (typically minor/patch within 9.x).

**Files**:

- `.bazelversion`
- `e2e/smoke/.bazelversion`
- `e2e/hello_world/.bazelversion`
- `e2e/library_deps/.bazelversion`
- `e2e/dart_test/.bazelversion`
- `e2e/analysis/.bazelversion`
- `e2e/web_app/.bazelversion`
- `e2e/pub_deps/.bazelversion`
- `e2e/pub_lock/.bazelversion`
- `e2e/gazelle/.bazelversion`
- `e2e/cross_compile/.bazelversion`
- `.bcr/presubmit.yml` — `bazel:` matrix value (if major version changes)
- `docs/ARCHITECTURE.md` — prose mentioning "Bazel 8.x" (if major version changes)

**Procedure**:

1. Update all `.bazelversion` files to the new version
2. If the major version changed, update `.bcr/presubmit.yml` matrix and `docs/ARCHITECTURE.md`
3. Regenerate lock files: `dart run tool/refresh_locks.dart`
4. Run `bazel test //dart/tests/...` to verify

**Verification**: `bazel test //dart/tests/...` passes.

**Automation**: `/bump-bazel {version}` slash command.

---

## Bazel Module Dependency Bumps

**Trigger**: Periodic (monthly) or when a dep releases a version we need.

**Files**:

- `MODULE.bazel` — `bazel_dep()` version strings
- E2e workspaces that duplicate deps:
  - `e2e/smoke/MODULE.bazel` — `bazel_skylib`
  - `e2e/gazelle/MODULE.bazel` — `bazel_skylib`, `gazelle`, `rules_go`
  - `e2e/cross_compile/MODULE.bazel` — `platforms`

**Procedure**:

1. For each `bazel_dep` in root `MODULE.bazel`, check latest version on BCR
2. Update versions, skip any already current
3. Mirror version changes to e2e workspaces that duplicate the same deps
4. Regenerate lock files: `dart run tool/refresh_locks.dart`
5. Run `bazel test //dart/tests/...` to verify

**Verification**: `bazel test //dart/tests/...` passes.

**Automation**: `/bump-deps` slash command.

---

## Lock File Refresh

**Trigger**: After any change to `MODULE.bazel` files or their transitive deps.

**Workspaces** (directories containing `MODULE.bazel`):

- `.` (root)
- `e2e/smoke`
- `e2e/hello_world`
- `e2e/library_deps`
- `e2e/dart_test`
- `e2e/analysis`
- `e2e/web_app`
- `e2e/pub_deps`
- `e2e/pub_lock`
- `e2e/gazelle`
- `e2e/cross_compile`

**Procedure**: Run `dart run tool/refresh_locks.dart`. This both refreshes
Bazel lock files (pulling fresh registry data, keeping MODULE.bazel
formatting canonical) and runs `dart pub get` in any in-repo Dart packages
(currently `dart/runfiles/`) to refresh their `pubspec.lock` files.

**Verification**: All workspaces and packages report success.

**Automation**: `/refresh-locks` slash command.

---

## Platform / Toolchain Expansion

**Trigger**: Dart SDK adds support for a new platform (rare).

**Files**:

- `dart/private/toolchains_repo.bzl` — `PLATFORMS` dict, possibly `CROSS_TARGETS`
- `dart/private/versions.bzl` — add platform key to each version entry
- `tool/fetch_sdk_hashes.dart` — add platform to `platforms` list
- `dart/tests/versions_test.bzl` — update platform count assertion
- `.bcr/presubmit.yml` — add platform to matrix if applicable
- `docs/ARCHITECTURE.md` — update platform list and cross-compilation matrix

**Procedure**: Add the platform to all files above, fetch hashes, update tests.

**Verification**: `bazel test //dart/tests/...` passes.

**Automation**: Manual — too rare and requires design decisions.

---

## E2e Pub Package Version Bumps

**Trigger**: When pub.dev packages used in e2e tests release new versions.

**Files**:

- `e2e/pub_deps/MODULE.bazel` — `pub.package()` version and sha256
- `e2e/pub_lock/pubspec.lock` — regenerate from `pubspec.yaml`

**Procedure**:

1. Check pub.dev for latest versions of packages used in e2e tests
2. Update `pub.package()` calls with new version and sha256
3. For `pub_lock`, run `dart pub get` in the e2e/pub_lock directory to refresh the lock file
4. Regenerate Bazel lock files

**Verification**: `bazel build //...` in affected e2e workspaces succeeds.

**Automation**: Manual — low frequency, requires checking sha256 hashes.

---

## In-repo Dart Package Maintenance

**Trigger**: Periodic or before a release.

**Packages**: `dart/runfiles/`

Each in-repo Dart package is publishable to pub.dev. Maintenance includes:

- **SDK constraint**: The `environment.sdk` lower bound in `pubspec.yaml`
  tracks the project's minimum supported Dart SDK. Updated by `/bump-dart-sdk`.
- **Dependencies**: Any pub dependencies need periodic bumping. Run
  `dart pub outdated` in the package directory to check.
- **Lock file**: `pubspec.lock` is refreshed automatically by
  `tool/refresh_locks.dart`.
- **Version**: Committed as `0.0.0-dev`. The real version is injected from
  the git tag at publish time by the release workflow.
- **Publishing**: Handled automatically by the `pub-publish` job in the
  release workflow (`.github/workflows/release.yaml`).

**Verification**: `dart pub get` succeeds; `dart pub outdated` reports no
critical updates.

**Automation**: `/maintenance-audit` checks SDK constraint consistency and
outdated dependencies.

---

## CI Folder List Sync

**Trigger**: When adding or removing an e2e workspace.

**Files**:

- `.github/workflows/ci.yaml` — `folders` array in the test job

**Procedure**:

1. Compare `e2e/*/MODULE.bazel` against the `folders` array in `ci.yaml`
2. Add/remove entries to match

**Verification**: CI workflow runs all e2e workspaces.

**Automation**: `/maintenance-audit` detects drift.

---

## BCR Presubmit Config

**Trigger**: When changing the test module or Bazel version requirements.

**Files**:

- `.bcr/presubmit.yml` — module_path, platform matrix, bazel matrix

**Procedure**: Update the YAML to match current requirements.

**Verification**: BCR presubmit passes after publishing.

**Automation**: Manual — changes are rare and coupled to other chores.

---

## Documentation Accuracy

**Trigger**: After any structural change (new rules, new e2e workspaces, etc.).

**Files**:

- `docs/ARCHITECTURE.md` — directory tree, provider table, testing table, e2e list
- `README.md` — examples table, installation snippet, version references

**Procedure**: Review hardcoded counts, tables, and version strings against actual state.

**Verification**: Visual inspection.

**Automation**: `/maintenance-audit` checks some of these.

---

## Pre-commit Hook Bumps

**Trigger**: New versions of pre-commit hooks (buildifier, etc.).

**Files**:

- `.pre-commit-config.yaml`

**Procedure**: Handled automatically by Renovate (`:enablePreCommit` preset).

**Verification**: Renovate opens PRs; CI runs pre-commit checks.

**Automation**: Renovate — no manual action needed.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Dependencies** (all `uses:` references across workflows):

- Actions: `actions/checkout`, `amannn/action-semantic-pull-request`,
  `dart-lang/setup-dart`, `smlx/ccv`, `pre-commit/action`,
  `technote-space/workflow-conclusion-action`
- Reusable workflows: `bazel-contrib/.github` (CI + release),
  `bazel-contrib/publish-to-bcr`

**Procedure**:

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Update the version ref
3. For reusable workflows, review changelogs for new inputs or breaking changes
4. Keep `actions/checkout` version consistent across all workflows

**Verification**: CI workflow runs successfully.

**Automation**: `/maintenance-audit` checks for outdated versions.
