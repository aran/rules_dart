# Maintenance Chores

Central reference for all recurring maintenance tasks. Keep file lists current
as the repo evolves.

---

## Dart SDK Version Bump

**Trigger**: New stable Dart SDK release.

**Files**:

- `dart/private/versions.bzl` — add new version entry to `TOOL_VERSIONS`, to
  `CROSS_TOOL_VERSIONS` and to `SOURCE_VERSIONS` (the source archive the
  outline stripper builds `pkg/kernel` from)
- `MODULE.bazel` — `dart.toolchain(dart_version = "...")`
- every other `MODULE.bazel` that pins one, the same
  `dart.toolchain(dart_version = "...")`
  (`git grep -l 'dart_version = "' -- '*MODULE.bazel'`), except the two in
  `e2e/failures/toolchain_pin_conflict`, whose versions are what that fixture tests
- `README.md` — `dart.toolchain(dart_version = "...")` in installation snippet
  (not the measurements that name the SDK they were taken on)
- `dart/tests/versions_test.bzl` — asserted version key in `_smoke_test_impl`
- `dart/runfiles/pubspec.yaml` — `environment.sdk` constraint (published to
  pub.dev; keep the lower bound as low as stays compatible rather than tracking
  the newest SDK)

**Procedure**:

1. Run `bazel run //tool:fetch_sdk_hashes -- {version}` to get SHA-256
   hashes
2. Add the three entries it prints to `dart/private/versions.bzl`, each as the
   first entry: the SDK checksums to `TOOL_VERSIONS`, the cross-compilation
   binaries' to `CROSS_TOOL_VERSIONS`, the tag's source archive to
   `SOURCE_VERSIONS` (the script downloads it twice and fails unless the two
   SHA-256s agree)
3. Update `dart_version` in all MODULE.bazel files listed above
4. Update the installation snippet in `README.md`
5. Update `dart/tests/versions_test.bzl` (asserted version key)
6. Regenerate lock files: `bazel run --lockfile_mode=off @overhead//locks:refresh`,
   then check that the `pubspec.lock` files still resolve on the new SDK:
   `bazel run //tool:pub_locks`
7. Run `bazel test //dart/tests/...` to verify unit tests pass. A failure in
   `//dart/tests/sdk_files` means the SDK moved or added a file one of its
   uses reads: update that use's entry in `SDK_FILE_SETS`
   (`dart/toolchain.bzl`) and its pin in `sdk_files_test.bzl`
   Check in particular that the SDK still ships the JIT
   `bin/snapshots/analysis_server.dart.snapshot`: the analysis worker
   launches it (`dart/private/tools/analysis_server.dart`,
   `dart/private/tools/server_analyzer.dart`) and breaks if it is gone, as
   dart-lang/sdk#63978 proposes by replacing app-JIT snapshots with AOT ones
8. Build the outline stripper on the new SDK's `pkg/kernel`,
   `@dart_kernel_source//:outline_tool`: a new `ProcedureStubKind` or
   other API change fails its compile, and must be classified in
   `kernel_outline.dart`, not defaulted. Read the VM's modular transforms
   (`pkg/vm/lib/modular/target/vm.dart`, `performModularTransformationsOnLibraries`)
   for any new one that reads a dependency's bodies, and add what it reads to
   the stripper's allowlist and to `//dart/tests/outline_fixture`. Then run the
   guard, which must pass:
   `bazel test --config=deep //dart/tests/outline_fixture:outline_guard_test`
9. Pick one e2e workspace and run `bazel build //...` to smoke-test
10. If the new SDK contains dart-lang/sdk e2c6325 (Mach-O `--strip` fix), retire
    `dart/private/tools/compile_runner.dart`: pass `--strip` to gen_snapshot
    (`--extra-gen-snapshot-options`) on macOS `exe` and `aot-snapshot`
    compiles, delete the runner and `dart_bootstrap_binary`, and keep
    `//dart/tests/reproducible_fixture` passing on macOS. Check that stripped
    stack traces still say enough; if not, keep the debugging info with
    `--save-debugging-info` beside the output. Then delete this step

**Verification**: `bazel test //dart/tests/...` passes; the outline guard
passes under `--config=deep`; at least one e2e workspace builds.

---

## Bazel Version Bump

**Trigger**: New Bazel release (typically minor/patch within 9.x).

**Files**:

- every `.bazelversion` (`git ls-files '*.bazelversion'`): the root's and each
  nested workspace's
- `.github/workflows/ci.yaml` — `bazel_versions:` must match `.bazelversion`; the
  reusable workflow sets `USE_BAZEL_VERSION` from it, so a stale value means CI
  never tests the version developers run locally
- `.bcr/presubmit.yml` — `bazel:` matrix value (if major version changes)
- `tools/preset.bazelrc` — generated for the Bazel version it runs on, and
  checked by CI's `lockfiles` job
- `docs/ARCHITECTURE.md` — prose naming the major Bazel version, "Bazel 9.x"
  (if major version changes)
- `MODULE.bazel` and `gazelle/MODULE.bazel` — the `bazel_compatibility` floor
  (if major version changes and the rules come to need the new major)

**Procedure**:

1. Update all `.bazelversion` files and `bazel_versions:` in
   `.github/workflows/ci.yaml` to the new version
2. If the major version changed, update `.bcr/presubmit.yml` matrix and `docs/ARCHITECTURE.md`
3. Regenerate the preset: `bazel run @overhead//preset`
4. Regenerate lock files: `bazel run --lockfile_mode=off @overhead//locks:refresh`
5. Run `bazel test //dart/tests/...` to verify

**Verification**: `bazel test //dart/tests/...` passes;
`bazel run @overhead//preset -- --check` passes.

---

## Bazel Module Dependency Bumps

**Trigger**: Periodic (monthly) or when a dep releases a version we need.

**Files**:

- `MODULE.bazel` — `bazel_dep()` version strings
- `gazelle/MODULE.bazel` (the Gazelle plugin's module) — `gazelle`, `rules_go`
- `dev/MODULE.bazel` — `bazel_skylib`, `gazelle`, `rules_go`,
  `bazel_skylib_gazelle_plugin`, and the Go SDK version
- `overhead/MODULE.bazel` — `rules_multitool`, `bazel_env.bzl` and
  `bazelrc-preset.bzl`. A `bazelrc-preset.bzl` bump changes the generated
  preset: rerun `bazel run @overhead//preset`
- `MODULE.bazel` — the `webcrypto_pub_archive` `http_archive` (not on BCR): a
  new `package:webcrypto` release means a new url and sha256, and moving the
  `webcrypto` bound in `dart/ext/registry.bzl` to that exact version
- E2e workspaces that declare the same deps:
  `git grep -n 'bazel_dep(' -- 'e2e/*MODULE.bazel'`
- `e2e/examples/native_assets/sqlite3_binary/test/direct_test.dart` — asserts the exact
  `sqlite3.version.libVersion` string, so a `sqlite3` bump fails this test until
  the literal is updated to match

**Procedure**:

1. For each `bazel_dep` in the files above, check latest version on BCR
2. Update versions, skip any already current
3. Mirror version changes to `gazelle/`, `dev/`, `overhead/` and the e2e
   workspaces that duplicate the same deps
4. If `bazelrc-preset.bzl` moved, regenerate the preset:
   `bazel run @overhead//preset`
5. Regenerate lock files: `bazel run --lockfile_mode=off @overhead//locks:refresh`
6. Run `bazel test //dart/tests/...` to verify

**Verification**: `bazel test //dart/tests/...` passes.

---

## Lock File Refresh

**Trigger**: After any change to `MODULE.bazel` files or their transitive deps.
A lock holds the module graph and the results of the extensions that are not
marked reproducible, each with its `bzlTransitiveDigest`: a dependency bump that
changes one of those extensions invalidates the lock of **every** workspace
using it. Under `--lockfile_mode=error`, which `.bazelrc` sets, that is a hard CI
failure. rules_dart's own extensions are reproducible, so Bazel keeps their
results in the output base, not the lock, and editing them changes no lock.

**Workspaces**: every directory with a tracked `MODULE.bazel`, found by
`bazel run @overhead//locks:check`, except a module nested in another
workspace with no tracked `MODULE.bazel.lock` of its own
(`e2e/examples/fixtures/pub_dedup/cross_module/module_b`, say), which resolves as part of it, and
a module the root's own `local_path_override` names without a `.bazelversion`
of its own, which resolves as part of the root. A nested module with a lock of
its own is a workspace.

A workspace that fails on purpose holds a `lock_expected_failure.txt` naming
what its failure prints (`git ls-files '*lock_expected_failure.txt'` lists
them; `e2e/failures/pub_archive_links` is one because its pub lock only exists while
its `check.dart` runs). The tool passes a step that fails with that text and
still refreshes the rest of the lock.

**Procedure**:

```shell
# every MODULE.bazel.lock, or some
bazel run --lockfile_mode=off @overhead//locks:refresh
bazel run --lockfile_mode=off @overhead//locks:refresh -- e2e/smoke
bazel run //tool:pub_locks -- --refresh  # pubspec.lock outside e2e/
```

The first two run `bazel mod tidy --lockfile_mode=refresh`, then `bazel mod deps`
and `bazel build --nobuild //...` with `--lockfile_mode=update`, in each
workspace, reading its committed `.bazelrc` but not its `.bazelrc.user`.
`bazel run @overhead//locks:check` checks instead (`--lockfile_mode=error`), and
`pub_locks` without `--refresh` runs `pub get --enforce-lockfile` on the pinned SDK; CI's
`lockfiles` job runs both.

The lock tool is built in the root workspace, so a refresh builds it with
`--lockfile_mode=off`, which neither reads nor writes the root lock: a stale
root lock cannot stop it, and `--override_module` flags in `.bazelrc.user`
cannot leak into that lock. The tool then rewrites the root lock itself. A
check needs no flag: a stale root lock fails it at Bazel's own "no longer
up-to-date" error.

`pub_locks` runs `pub get` on the pinned SDK (`bazel run @rules_dart//dart/pub`)
in every tracked Dart package outside `e2e/` and `dev/testdata/`, whose locks
are fixtures: `dart/ext/`, `dart/private/tools/`, `dart/runfiles/` and
`overhead/`.

**Verification**: All workspaces and packages report success.

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
- `e2e/examples/cross_compile/BUILD.bazel` — add to `_TARGETS`
- `e2e/examples/cross_compile/cross_compile_test.dart` — add its expected `EI_CLASS`
  and `e_machine` to the table; the suite asserts the architectures are pairwise
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
bazel run @rules_dart//dart -- compile exe          -o /tmp/x hello.dart --target-os linux --target-arch <arch>
bazel run @rules_dart//dart -- compile aot-snapshot -o /tmp/x.aot hello.dart --target-os linux --target-arch <arch>
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
`PLATFORMS` exactly. Then `cd e2e/examples && bazel test //cross_compile/...`
for the byte-level architecture check.

**Automation**: Manual — too rare and requires design decisions.

---

## E2e Pub Package Version Bumps

**Trigger**: When pub.dev packages used in e2e tests release new versions.

**Files**:

- the e2e `pub.package()` calls
  (`git grep -n 'pub.package(' -- 'e2e/*MODULE.bazel'`): version and sha256.
  `very_good_analysis`, the lint set most workspaces analyze under, moves in
  all of them together, as does `e2e/examples/pub/package`'s `path`. A pin whose version
  is what its fixture tests stays put: two versions of one package across a
  root and its `dep_mod` or `mod_b` (`e2e/root_settings/pub_versions/highest_wins`,
  `e2e/root_settings/pub_versions/override_root_lock`,
  `e2e/failures/pub_lock_conflict`), or a fixture that fails on purpose
- `e2e/examples/pub/lock/pubspec.lock` — regenerate from `pubspec.yaml`. The other e2e
  `pubspec.lock` files are fixtures, read as they are

**Procedure**:

1. Check pub.dev for latest versions of the packages above
2. Update `pub.package()` calls with new version and sha256
3. For `examples/pub/lock`, run `bazel run @rules_dart//dart/pub -- get --directory=e2e/examples/pub/lock`
   to refresh the lock file
4. Regenerate Bazel lock files:
   `bazel run --lockfile_mode=off @overhead//locks:refresh`

**Verification**: `bazel build //...` in affected e2e workspaces succeeds.

**Automation**: Manual — low frequency, requires checking sha256 hashes.

---

## In-repo Dart Package Maintenance

**Trigger**: Periodic or before a release.

**Packages**: `dart/runfiles/`, published to pub.dev, and `dart/ext/`,
`dart/private/tools/` and `overhead/`, which are `publish_to: none`.
Maintenance includes:

- **SDK constraint**: `dart/runfiles/`'s `environment.sdk` lower bound stays
  as low as remains compatible, not tracking the newest SDK.
- **Dependencies**: Any pub dependencies need periodic bumping. Run
  `bazel run @rules_dart//dart/pub -- outdated --directory=<package>` to check,
  then `... -- upgrade --directory=<package>` to take what the current
  constraints allow.

  `dart/ext/` moves as a deliberate chore, not with the routine sweep. Its
  lock is `ext_pub_deps`, shared with every workspace that runs codegen, and
  there is one version per package across all locks, the highest any of them
  asks for. A consumer's newer version wins over ours silently; ours raising a
  consumer's lock warns them, naming `ext_pub_deps`. The graph rides the
  newest analyzer line every builder accepts, and the `build` major that
  every generator accepts (`source_gen` aside, they cap it below 5).
  `e2e/examples/codegen`,
  `e2e/examples/tests/package_test`, and rules_dart_proto's `dart_proto` set floors on
  `analyzer`/`package_config` in their pubspecs to keep their locks no older
  than this one. To bump:
  `bazel run @rules_dart//dart/pub -- upgrade --directory=dart/ext`, then
  the same `upgrade` with each pinned workspace's `--directory`, refresh the touched
  `MODULE.bazel.lock`s, and verify with `//dart/ext/...`,
  `e2e/examples/codegen`, and a consuming app. A shim needs changing only when a
  builder's entrypoint signature changes, so builder majors are usually cheap.

- **Lock file**: `pubspec.lock` is refreshed by
  `bazel run //tool:pub_locks -- --refresh`.
- **Version** (`dart/runfiles/`): Committed as `0.0.0-dev`. The real version
  is injected from the git tag at publish time by the release workflow.
- **Publishing** (`dart/runfiles/`): Handled automatically by the
  `pub-publish` job in the release workflow (`.github/workflows/release.yaml`).

**Verification**: `pub get` succeeds; `pub outdated` reports no critical
updates (both through `bazel run @rules_dart//dart/pub`).

---

## CI Folder List Sync

**Trigger**: When adding or removing an e2e workspace.

**Files**:

- `.github/workflows/ci.yaml` — `folders` array in the test job.
  `tools/vm/e2e_items.dart` reads it from there.

**Procedure**:

1. Compare `e2e/*/MODULE.bazel` against the `folders` array in `ci.yaml`.
   A workspace the `test` job cannot run as it is runs in the job made for
   it instead, and stays out of `folders`: each one under `e2e/failures`,
   which has a `lock_expected_failure.txt` (`expected-failure`, or
   `pub-archive-links` for `e2e/failures/pub_archive_links`)
2. Add/remove entries to match

**Verification**: CI workflow runs all e2e workspaces.

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

---

## Multitool Version Bumps

**Trigger**: Periodic (monthly) or when a managed tool releases a version we need.

**Files**:

- `overhead/multitool.lock.json` — tool versions, URLs, and SHA-256 hashes,
  for every repository that uses overhead

**Managed tools**: `actionlint`, `buildifier`, `git-cliff`, `prek`, `shellcheck`,
`typos`, `yamlfmt`

**Procedure**:

1. For each tool in `overhead/multitool.lock.json`, check its GitHub releases
   for newer versions. Take prek no newer than the newest that
   `j178/prek-action` knows a checksum for, for the repositories whose CI
   installs prek with that action.
2. Download archives for all platform variants (macOS/Linux, arm64/x86_64)
3. Compute SHA-256 hashes and update the lockfile entries
4. Regenerate lock files: `bazel run --lockfile_mode=off @overhead//locks:refresh`
5. Run `bazel run @overhead//lint:prek -- run --all-files --hook-stage manual`
   to verify the updated tools work, `uv tool upgrade prek` so the installed
   git hooks use a prek at least as new, and
   `bazel run --noincompatible_auto_exec_groups @overhead//:bazel_env` so the
   hooks run the new tools.

**Verification**: The hooks pass.

The hooks run overhead's tools, so there is no second pin to keep in step.

With the [multitool CLI](https://github.com/theoremlp/multitool) installed, run
`multitool --lockfile ./overhead/multitool.lock.json update`.

---

## Git Hook Bumps

**Trigger**: New versions of the hook repositories `.pre-commit-config.yaml`
pins by rev (`pre-commit-hooks`, etc.).

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

- Actions: `actions/checkout`, `bazel-contrib/setup-bazel`,
  `dart-lang/setup-dart`, `smlx/ccv`
- Reusable workflows: `bazel-contrib/.github` (CI + release),
  `bazel-contrib/publish-to-bcr`

**Procedure**:

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Update the commit SHA and the trailing version comment together
   (`uses: owner/repo@<sha> # v1.2.3`); references are SHA-pinned, except
   the two reusable workflows that make the release's attestations
   (`bazel-contrib/.github`'s `release_ruleset.yaml` and
   `bazel-contrib/publish-to-bcr`), which stay on a tag: BCR checks the
   attestations with the SLSA verifier, which refuses a commit ref
3. For reusable workflows, review changelogs for new inputs or breaking changes
4. Keep `actions/checkout` version consistent across all workflows

**Verification**: CI workflow runs successfully.

---

## Build Benchmark

**Trigger**: A change that may make users wait longer or shorter: compile
actions, early cutoff, workers, analysis, codegen, Gazelle's target layout.

**Files**: `tools/bench/` (the `dart_binary` and its scenarios), the
`bench_pub_source` archive in `MODULE.bazel`.

The bench is run by hand on one machine and compares two rules_dart commits.
It is never part of `bazel test //...` or CI: timings are noisy and
machine-bound. The target is `manual`, so `//...` neither builds it nor
fetches the source it carries.

It builds two workspaces in a scratch directory, each with its own output
base, from the checkout `bazel run` is started in:

- dart-lang/pub at a fixed commit, with BUILD files the Gazelle plugin
  writes when the bench sets it up;
- a copy of `e2e/examples`, for codegen (its `builders`).

| Scenario             | What it measures                                                                     |
| -------------------- | ------------------------------------------------------------------------------------ |
| `pub_cold_build`     | `bazel build` of pub's library, bin and every test target after `clean`, `shutdown`  |
| `pub_body_edit`      | rebuild after a body-only edit in pub's library (the early-cutoff path)              |
| `pub_api_edit`       | rebuild after adding a public function to that library                               |
| `pub_test`           | `bazel test` of the pub tests in `tools/bench/pub_tests.txt`, warm, uncached results |
| `pub_analysis_cold`  | the `dart_analyze` aspect over pub after `clean` and `shutdown` (no workers)         |
| `pub_analysis_warm`  | the aspect after a body-only edit, workers warm                                      |
| `codegen_cold_build` | `e2e/examples` builders that consume generated code, cold (no C)                    |
| `codegen_edit`       | rebuild after adding a `@JsonSerializable` class                                     |

A cold build keeps the fetched repositories and turns the disk cache off;
`--disk_cache=` is on every command. `pub_tests.txt` holds the pub tests that
pass under Bazel: most of pub's tests run `bin/pub.dart` from pub's own source
tree at run time, which a Bazel test does not have.

**Procedure**:

1. Make the machine quiet: no other builds. The bench records the load
   average and the other Bazel servers when it starts, and the CPU other Bazel
   servers use during each measured command, and warns when either is high.
   A run with warnings is not a measurement.
2. Run it in each checkout to compare, the same way. For a commit other than
   the current one, use a worktree:
   ```
   git worktree add ../rules_dart-before <commit>
   (cd ../rules_dart-before && bazel run //tools/bench -- --out=/tmp/before.json)
   bazel run //tools/bench -- --out=/tmp/after.json
   bazel run //tools/bench -- compare /tmp/before.json /tmp/after.json
   ```
   Options: `--runs=N` (default 3), `--scenarios=pub_body_edit,pub_api_edit`,
   `--scratch=DIR`, `--keep` to keep the scratch directory. The worktree needs
   the checkout's untracked `.bazelrc.user` and `tools/bazel`, if it has them:
   the bench copies both into its workspaces, so that it runs Bazel the way
   the checkout does.
3. Each run writes the JSON result, the same table as Markdown beside it
   (`.md`), and every command's `--profile` in a `.profiles` directory, for
   `bazel analyze-profile` when a number needs explaining. The table gives the
   median wall time (with the least and greatest), Bazel's own wall time, the
   critical path and the actions executed.
4. The scratch directory, output bases included (several GB), is deleted
   when the run ends unless `--keep` is given.

**Moving pub to a newer commit**: update `bench_pub_source` (URL, strip
prefix, sha256), run `pub_test` and rewrite `pub_tests.txt` to the tests that
pass, and check the edits `tools/bench/scenarios.dart` makes still apply (it
fails naming the file when an anchor is gone).
