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
- `e2e/dart_test_pkg/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/analysis/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/analysis_failure/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/web_app/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/pub_deps/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/pub_lock/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/gazelle/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/cross_compile/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/pub_lock_conflict/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/pub_lock_cross_module/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/pub_lock_dedup/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/pub_lock_upgrade/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/codegen/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/dual_build/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/ext_exemplar/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/fix/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `README.md` — `dart.toolchain(dart_version = "...")` in installation snippet
- `dart/tests/versions_test.bzl` — asserted version key in `_smoke_test_impl`
- `dart/runfiles/pubspec.yaml` — `environment.sdk` constraint (published to
  pub.dev; keep the lower bound as low as stays compatible rather than tracking
  the newest SDK)

**Procedure**:

1. Run `dart run tool/fetch_sdk_hashes.dart {version}` to get SHA-256 hashes
2. Add the new version entry to `dart/private/versions.bzl`
3. Update `dart_version` in all MODULE.bazel files listed above
4. Update version references in `README.md`
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
- `e2e/dart_test_pkg/.bazelversion`
- `e2e/analysis/.bazelversion`
- `e2e/analysis_failure/.bazelversion`
- `e2e/web_app/.bazelversion`
- `e2e/pub_deps/.bazelversion`
- `e2e/pub_lock/.bazelversion`
- `e2e/gazelle/.bazelversion`
- `e2e/cross_compile/.bazelversion`
- `e2e/pub_lock_conflict/.bazelversion`
- `e2e/pub_lock_cross_module/.bazelversion`
- `e2e/pub_lock_dedup/.bazelversion`
- `e2e/pub_lock_upgrade/.bazelversion`
- `e2e/codegen/.bazelversion`
- `e2e/dual_build/.bazelversion`
- `e2e/ext_exemplar/.bazelversion`
- `e2e/fix/.bazelversion`
- `.github/workflows/ci.yaml` — `bazel_versions:` must match `.bazelversion`; the
  reusable workflow sets `USE_BAZEL_VERSION` from it, so a stale value means CI
  never tests the version developers run locally
- `.bcr/presubmit.yml` — `bazel:` matrix value (if major version changes)
- `docs/ARCHITECTURE.md` — prose naming the major Bazel version, currently
  "Bazel 9.x" (if major version changes)

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
  - `e2e/smoke/MODULE.bazel` — `bazel_skylib`, `rules_shell`
  - `e2e/codegen/MODULE.bazel` — `bazel_skylib`
  - `e2e/gazelle/MODULE.bazel` — `bazel_skylib`, `gazelle`, `rules_shell`
  - `e2e/cross_compile/MODULE.bazel` — `platforms`, `rules_platform`
  - `e2e/dual_build/MODULE.bazel` — `rules_shell`
  - `e2e/ext_exemplar/MODULE.bazel` — `gazelle`, `rules_go`, `sqlite3`,
    `rules_cc`, `platforms`
  - `e2e/fix/MODULE.bazel` — `bazel_skylib`
- `e2e/ext_exemplar/sqlite3_binary/test/direct_test.dart` — asserts the exact
  `sqlite3.version.libVersion` string, so a `sqlite3` bump fails this test until
  the literal is updated to match

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

**Trigger**: After any change to `MODULE.bazel` files or their transitive deps —
and after any change to a `.bzl` file reachable from a module extension. A lock
records each extension's `bzlTransitiveDigest`, so editing (or merely adding a
load to) anything in `dart/pub/extensions.bzl`'s closure invalidates the lock of
**every** workspace using it, not just the one whose `MODULE.bazel` moved. Under
`--lockfile_mode=error`, which `.bazelrc` sets, that is a hard CI failure.

**Workspaces** (directories containing `MODULE.bazel`):

- `.` (root)
- `e2e/smoke`
- `e2e/hello_world`
- `e2e/library_deps`
- `e2e/dart_test`
- `e2e/dart_test_pkg`
- `e2e/analysis`
- `e2e/analysis_failure`
- `e2e/web_app`
- `e2e/pub_deps`
- `e2e/pub_lock`
- `e2e/gazelle`
- `e2e/cross_compile`
- `e2e/pub_lock_cross_module`
- `e2e/pub_lock_dedup`
- `e2e/pub_lock_upgrade`
- `e2e/codegen`
- `e2e/dual_build`
- `e2e/ext_exemplar`
- `e2e/fix`

Two workspaces are deliberately skipped by the tool (`_skipWorkspaces` in
`tool/refresh_locks.dart`) because they don't resolve standalone:
`e2e/pub_lock_conflict` (intentionally conflicting lock files) and
`e2e/pub_lock_cross_module/module_b` (consumed only from its parent). Their
locks still get updated as a side effect of building those workspaces.

**Procedure**: Run `dart run tool/refresh_locks.dart`. This both refreshes
Bazel lock files (pulling fresh registry data, keeping MODULE.bazel
formatting canonical) and runs `dart pub get` in any in-repo Dart packages
(currently `dart/runfiles/`) to refresh their `pubspec.lock` files.

**Verification**: All workspaces and packages report success.

**Automation**: `/refresh-locks` slash command.

---

## Platform / Toolchain Expansion

**Trigger**: Dart SDK adds support for a new platform (rare).

There are two distinct procedures. Pick by asking whether the platform can be a
**host** — i.e. whether Bazel itself publishes a release for that OS/CPU. If it
cannot, it is a cross-only target and costs no checksums.

### A new cross-only target (the common case)

**Files**:

- `dart/private/toolchains_repo.bzl` — add to `TARGET_ONLY_PLATFORMS`, then add
  it to each `CROSS_TARGETS` value it is reachable from
- `e2e/cross_compile/BUILD.bazel` — add to `_TARGETS`
- `e2e/cross_compile/cross_compile_test.dart` — add its expected `EI_CLASS` and
  `e_machine` to the table; the suite asserts the architectures are pairwise
  distinct, so a new target must bring a new `e_machine`
- `dart/tests/cross_fixture/BUILD.bazel` — a `platform()` plus flag/ABI tests
- `dart/private/common.bzl` — extend `DART_ABI_CONSTRAINT_ATTRS` and
  `target_dart_abi` if the CPU is new, so code assets are not blocked for users
  who bring their own cc toolchain
- `docs/ARCHITECTURE.md` — platform list, toolchain counts, cross matrix

Explicitly **not** needed: `versions.bzl`, `tool/fetch_sdk_hashes.dart`, and
`.bcr/presubmit.yml`. A cross toolchain reuses the host SDK's `dart` binary, so
no SDK is downloaded for the target and no checksum exists to fetch. BCR CI has
no runner for these CPUs either.

Before hard-coding the ELF table, confirm the real header bytes:

```sh
dart compile exe          -o /tmp/x hello.dart --target-os linux --target-arch <arch>
dart compile aot-snapshot -o /tmp/x.aot hello.dart --target-os linux --target-arch <arch>
file /tmp/x /tmp/x.aot
```

### A new host platform

**Files**: everything above, plus

- `dart/private/toolchains_repo.bzl` — `PLATFORMS` rather than `TARGET_ONLY_PLATFORMS`
- `dart/private/versions.bzl` — add the platform key to **every** version entry;
  `repositories.bzl` hard-errors on a missing key
- `tool/fetch_sdk_hashes.dart` — add to the `platforms` list, then re-run it for
  every pinned version
- `.bcr/presubmit.yml` — add to the matrix if BCR has a runner

**Verification**: `bazel test //dart/tests/...` — `toolchains_test.bzl` asserts
the table invariants, including that every pinned version's checksum set matches
`PLATFORMS` exactly. Then `cd e2e/cross_compile && bazel test //...` for the
byte-level architecture check.

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
  `dart pub outdated` in the package directory to check, then `dart pub upgrade`
  to take what the current constraints allow.

  `dart/ext/` moves as a deliberate chore, not with the routine sweep. Its
  lock is `ext_pub_deps`, shared with every workspace that runs codegen, and
  the pub extension fails the build when a package resolves to two versions
  across locks. The graph rides the newest analyzer line every builder
  accepts: today that is analyzer 13.x — `drift_dev` caps `analyzer` <14 and
  `package_config` <3, so those majors wait on drift. `e2e/codegen`,
  `e2e/dart_test_pkg`, and rules_dart_proto's `dart_proto` pin
  `analyzer`/`package_config` in their pubspecs to hold their locks on the
  same line. To bump: `dart pub upgrade` in `dart/ext/` (needs a
  Flutter-flavored pub — `go_router_builder` declares a Flutter environment
  constraint), then `dart pub upgrade` in each pinned workspace, refresh the
  touched `MODULE.bazel.lock`s, and verify with `//dart/ext/...`,
  `e2e/codegen`, and a consuming app. The freezed 3.2→4.0 / analyzer 10→13
  bump needed no shim changes — every shim compiled and analyzed clean
  unchanged — so expect builder majors to be cheap unless a builder
  entrypoint signature changes.

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

- `docs/ARCHITECTURE.md` — provider table, testing table, design rationale
- `README.md` — examples table, installation snippet, version references

**Procedure**: Review hardcoded counts, tables, and version strings against actual state.

**Verification**: Visual inspection.

**Automation**: `/maintenance-audit` checks some of these.

---

## Multitool Version Bumps

**Trigger**: Periodic (monthly) or when a managed tool releases a version we need.

**Files**:

- `multitool.lock.json` — tool versions, URLs, and SHA-256 hashes

**Managed tools**: `yamlfmt`, `typos`

**Procedure**:

1. For each tool in `multitool.lock.json`, check its GitHub releases for newer versions
2. Download archives for all platform variants (macOS/Linux, arm64/x86_64)
3. Compute SHA-256 hashes and update the lockfile entries
4. Regenerate lock files: `dart run tool/refresh_locks.dart`
5. Run `bazel run @multitool//tools/yamlfmt -- -lint .` and
   `bazel run @multitool//tools/typos -- .` to verify the updated tools work

**Verification**: Both tools run successfully against the repo.

Also update the matching `rev:` values in `.pre-commit-config.yaml` for yamlfmt
and typos to keep CI and local hooks in sync.

**Automation**: `/bump-multitool` slash command. Alternatively, install the
[multitool CLI](https://github.com/theoremlp/multitool) and run
`multitool --lockfile ./multitool.lock.json update`.

---

## Pre-commit Hook Bumps

**Trigger**: New versions of pre-commit hooks (buildifier, etc.).

**Files**:

- `.pre-commit-config.yaml`

**Procedure**: Run `pre-commit autoupdate`, then reconcile the revs that are
pinned to something else in this repo:

- `keith/pre-commit-buildifier` should track `buildifier_prebuilt` in
  `MODULE.bazel`, so the hook and CI format identically. Match on the buildifier
  version — the first three components — not the fourth, which is the ruleset's
  own packaging revision: `buildifier_prebuilt` 8.5.1.3 and 8.5.1.4 ship the
  same buildifier 8.5.1, and the mirror repo tags only some of those revisions
  (it has no 8.5.1.4). A fourth-component gap is not drift.
- `google/yamlfmt` and `crate-ci/typos` should track `multitool.lock.json`
  (see § "Multitool Version Bumps").
- `pre-commit/mirrors-prettier` is archived upstream; `v3.1.0` is the last
  stable tag and is expected to stay pinned. Do not "upgrade" it to the
  `v4.0.0-alpha` tags.

**Verification**: `pre-commit run --all-files` passes.

**Automation**: Manual. These were previously assumed to be handled by
Renovate, but no Renovate config has ever existed in this repo, and the
buildifier and commitizen revs silently drifted as a result.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Dependencies** (all `uses:` references across workflows):

- Actions: `actions/checkout`, `amannn/action-semantic-pull-request`,
  `dart-lang/setup-dart`, `smlx/ccv`, `pre-commit/action`
- Reusable workflows: `bazel-contrib/.github` (CI + release),
  `bazel-contrib/publish-to-bcr`

**Procedure**:

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Update the version ref
3. For reusable workflows, review changelogs for new inputs or breaking changes
4. Keep `actions/checkout` version consistent across all workflows

**Verification**: CI workflow runs successfully.

**Automation**: `/bump-workflows` slash command. `/maintenance-audit` checks for outdated versions.
