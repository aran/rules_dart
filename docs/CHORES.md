# Maintenance Chores

Central reference for all recurring maintenance tasks. Slash commands read this
file at runtime — keep file lists current as the repo evolves.

---

## Dart SDK Version Bump

**Trigger**: New stable Dart SDK release.

**Files**:

- `dart/private/versions.bzl` — add new version entry to `TOOL_VERSIONS` and to `CROSS_TOOL_VERSIONS`
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
- `e2e/link_hook/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/analyze_composition/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `e2e/analyze_composition/dep_module/MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- `README.md` — `dart.toolchain(dart_version = "...")` in installation snippet
- `dart/tests/versions_test.bzl` — asserted version key in `_smoke_test_impl`
- `dart/runfiles/pubspec.yaml` — `environment.sdk` constraint (published to
  pub.dev; keep the lower bound as low as stays compatible rather than tracking
  the newest SDK)

**Procedure**:

1. Run `dart run tool/fetch_sdk_hashes.dart {version}` to get SHA-256 hashes
2. Add its two entries to `dart/private/versions.bzl`: the SDK checksums to
   `TOOL_VERSIONS`, the cross-compilation binaries' to `CROSS_TOOL_VERSIONS`
3. Update `dart_version` in all MODULE.bazel files listed above
4. Update version references in `README.md`
5. Update `dart/tests/versions_test.bzl` (asserted version key)
6. Regenerate lock files: `bazel run --lockfile_mode=off @overhead//locks -- --refresh`
7. Run `bazel test //dart/tests/...` to verify unit tests pass
8. Pick one e2e workspace and run `bazel build //...` to smoke-test
9. If the new SDK contains dart-lang/sdk e2c6325 (Mach-O `--strip` fix), retire
   `dart/private/tools/compile_runner.dart`: pass `--strip` to gen_snapshot
   (`--extra-gen-snapshot-options`) on macOS `exe` and `aot-snapshot`
   compiles, delete the runner and `dart_bootstrap_binary`, and keep
   `//dart/tests/reproducible_fixture` passing on macOS. Check that stripped
   stack traces still say enough; if not, keep the debugging info with
   `--save-debugging-info` beside the output. Then delete this step and step 11
   of `.claude/commands/bump-dart-sdk.md`

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
3. Regenerate lock files: `bazel run --lockfile_mode=off @overhead//locks -- --refresh`
4. Run `bazel test //dart/tests/...` to verify

**Verification**: `bazel test //dart/tests/...` passes.

**Automation**: `/bump-bazel {version}` slash command.

---

## Bazel Module Dependency Bumps

**Trigger**: Periodic (monthly) or when a dep releases a version we need.

**Files**:

- `MODULE.bazel` — `bazel_dep()` version strings
- `MODULE.bazel` — the `webcrypto_pub_archive` `http_archive` (not on BCR): a
  new `package:webcrypto` release means a new url and sha256, and moving the
  `webcrypto` bound in `dart/ext/registry.bzl` to that exact version
- E2e workspaces that duplicate deps:
  - `e2e/smoke/MODULE.bazel` — `bazel_skylib`, `rules_shell`
  - `e2e/codegen/MODULE.bazel` — `bazel_skylib`
  - `e2e/gazelle/MODULE.bazel` — `bazel_skylib`, `gazelle`, `rules_shell`,
    `apple_support`
  - `e2e/cross_compile/MODULE.bazel` — `platforms`, `rules_platform`
  - `e2e/dual_build/MODULE.bazel` — `rules_shell`
  - `e2e/ext_exemplar/MODULE.bazel` — `gazelle`, `rules_go`, `sqlite3`,
    `rules_cc`, `platforms`, `apple_support`
  - `e2e/fix/MODULE.bazel` — `bazel_skylib`
- `e2e/ext_exemplar/sqlite3_binary/test/direct_test.dart` — asserts the exact
  `sqlite3.version.libVersion` string, so a `sqlite3` bump fails this test until
  the literal is updated to match

**Procedure**:

1. For each `bazel_dep` in root `MODULE.bazel`, check latest version on BCR
2. Update versions, skip any already current
3. Mirror version changes to e2e workspaces that duplicate the same deps
4. Regenerate lock files: `bazel run --lockfile_mode=off @overhead//locks -- --refresh`
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

**Workspaces**: every directory with a tracked `MODULE.bazel`, found by
`bazel run @overhead//locks`, except a module inside another e2e workspace
(`e2e/pub_lock_cross_module/module_b`, say), which resolves as part of it, and
a module the root's own `local_path_override` names without a `.bazelversion`
of its own, which resolves as part of the root.

A workspace that fails on purpose holds a `lock_expected_failure.txt` naming
what its failure prints (`e2e/pub_lock_conflict`, `e2e/pub_package_conflict`,
`e2e/pub_lock_path_override`,
the sha256 refusals, and `e2e/pub_archive_links`, whose pub lock only exists
while its `check.dart` runs). The tool passes a step that fails with that text
and still refreshes the rest of the lock.

**Procedure**:

```shell
# every MODULE.bazel.lock, or some
bazel run --lockfile_mode=off @overhead//locks -- --refresh
bazel run --lockfile_mode=off @overhead//locks -- --refresh e2e/smoke
bazel run //tool:pub_locks -- --refresh  # pubspec.lock outside e2e/
```

The first runs `bazel mod tidy --lockfile_mode=refresh`, then `bazel mod deps`
and `bazel build --nobuild //...` with `--lockfile_mode=update`, in each
workspace, reading its committed `.bazelrc` but not its `.bazelrc.user`.
Without `--refresh` they check instead (`--lockfile_mode=error`;
`dart pub get --enforce-lockfile`), which CI's `lockfiles` job runs.

The lock tool is built in the root workspace, so a refresh builds it with
`--lockfile_mode=update`: a stale root lock would otherwise stop it before it
could rewrite anything. A check runs without that flag, since Bazel would then
quietly rewrite a stale root lock before the tool checked it; a stale root lock
fails the check at Bazel's own "no longer up-to-date" error instead.

`pub_locks` runs `dart pub get` in the in-repo Dart packages (`dart/ext/`,
`dart/private/tools/`, `dart/runfiles/`, `overhead/`) on the pinned SDK
(`bazel run @rules_dart//dart`), since a package's SDK floor can be ahead of
the host's `dart`, with `FLUTTER_ROOT` taken from the environment or the
`flutter` on PATH: `dart/ext/` needs a Flutter-flavored pub.

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

- `tool/fetch_sdk_hashes.dart` — add it to the `crossTargets` values, mirroring
  `CROSS_TARGETS`, then re-run it for every pinned version and replace each
  `CROSS_TOOL_VERSIONS` entry in `dart/private/versions.bzl`

Explicitly **not** needed: `TOOL_VERSIONS` and `.bcr/presubmit.yml`. A cross
toolchain reuses the host SDK's `dart` binary, so no SDK is downloaded for the
target; only its `gen_snapshot` and `dartaotruntime` are. BCR CI has no runner
for these CPUs either.

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
- `tool/fetch_sdk_hashes.dart` — add to the `platforms` list (and to
  `crossTargets` if it can cross-compile), then re-run it for every pinned
  version
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
  there is one version per package across all locks. `ext_pub_deps` sets
  `on_version_conflict = "upgrade"`, so a consumer's newer version wins over
  ours, but a consumer lock _older_ than ours for a shared package still
  fails the build unless that consumer sets it too. The graph rides the
  newest analyzer line every builder accepts: today that is analyzer 14.x,
  while `build` stays on 4.x because every generator except `source_gen`
  caps it below 5. `e2e/codegen`,
  `e2e/dart_test_pkg`, and rules_dart_proto's `dart_proto` set floors on
  `analyzer`/`package_config` in their pubspecs to keep their locks no older
  than this one. To bump:
  `FLUTTER_ROOT=<flutter sdk> bazel run @rules_dart//dart -- pub upgrade` in
  `dart/ext/` (it needs a Flutter-flavored pub on the pinned SDK —
  `go_router_builder` declares a Flutter environment constraint), then
  `dart pub upgrade` in each pinned workspace, refresh the touched
  `MODULE.bazel.lock`s, and verify with `//dart/ext/...`,
  `e2e/codegen`, and a consuming app. The analyzer 10→13 and 13→14 bumps
  needed no shim changes — every shim compiled and analyzed clean
  unchanged — so expect builder majors to be cheap unless a builder
  entrypoint signature changes.

- **Lock file**: `pubspec.lock` is refreshed by
  `bazel run //tool:pub_locks -- --refresh`.
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

- `overhead/multitool.lock.json` — tool versions, URLs, and SHA-256 hashes,
  for every repository that uses overhead

**Managed tools**: `git-cliff`, `prek`, `typos`, `yamlfmt`

**Procedure**:

1. For each tool in `overhead/multitool.lock.json`, check its GitHub releases
   for newer versions. Take prek no newer than the newest that
   `j178/prek-action` knows a checksum for, for the repositories whose CI
   installs prek with that action.
2. Download archives for all platform variants (macOS/Linux, arm64/x86_64)
3. Compute SHA-256 hashes and update the lockfile entries
4. Regenerate lock files: `bazel run --lockfile_mode=off @overhead//locks -- --refresh`
5. Run `bazel run @overhead//lint:prek -- run --all-files --hook-stage manual`
   to verify the updated tools work, `uv tool upgrade prek` so the installed
   git hooks use a prek at least as new, and
   `bazel run --noincompatible_auto_exec_groups @overhead//:bazel_env` so the
   hooks run the new typos and yamlfmt.

**Verification**: The hooks pass.

The hooks run yamlfmt and typos through overhead, so there is no second pin to
keep in step.

**Automation**: `/bump-multitool` slash command. Alternatively, install the
[multitool CLI](https://github.com/theoremlp/multitool) and run
`multitool --lockfile ./overhead/multitool.lock.json update`.

---

## Git Hook Bumps

**Trigger**: New versions of the git hooks (buildifier, etc.).

**Files**:

- `.pre-commit-config.yaml`

**Procedure**: Run `prek autoupdate`, then reconcile the revs that are
pinned to something else in this repo:

- buildifier is pinned in `overhead/multitool.lock.json` (from
  `bazelbuild/buildtools` releases), not by a hook rev; bump it with the other
  multitool tools.
- `pre-commit/mirrors-prettier` is archived upstream; `v3.1.0` is the last
  stable tag and is expected to stay pinned. Do not "upgrade" it to the
  `v4.0.0-alpha` tags.

**Verification**: `prek run --all-files` passes.

**Automation**: Manual.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Dependencies** (all `uses:` references across workflows):

- Actions: `actions/checkout`, `amannn/action-semantic-pull-request`,
  `dart-lang/setup-dart`, `smlx/ccv`, `j178/prek-action`
- Reusable workflows: `bazel-contrib/.github` (CI + release),
  `bazel-contrib/publish-to-bcr`

**Procedure**:

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Update the version ref
3. For reusable workflows, review changelogs for new inputs or breaking changes
4. Keep `actions/checkout` version consistent across all workflows

**Verification**: CI workflow runs successfully.

**Automation**: `/bump-workflows` slash command. `/maintenance-audit` checks for outdated versions.
