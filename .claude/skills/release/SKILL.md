---
name: release
description: Drive a rules_dart release end-to-end — local readiness checks, validate dependent repos against the WIP checkout, push, watch CI, tag, mark the BCR draft PR ready, and wait for BCR + pub.dev to serve it; then cascade the same to rules_dart_proto. Use when the user asks to cut, ship, publish, or release a new rules_dart version.
---

# Release rules_dart

A release of rules_dart cascades to two downstream repos. This runbook drives the
whole sequence. **You execute it interactively with the user in the loop** — stop
and ask whenever a gate is ambiguous or something looks off. Do not power through
failures.

## The repos

| Repo               | Local clone                       | Releases to                     | Notes                                                    |
| ------------------ | --------------------------------- | ------------------------------- | -------------------------------------------------------- |
| `rules_dart`       | `$HOME/Projects/rules_dart`       | BCR + pub.dev (`dart/runfiles`) | this repo                                                |
| `rules_dart_proto` | `$HOME/Projects/rules_dart_proto` | BCR                             | pins `rules_dart`; **version-aligned** with it           |
| `rules_flutter`    | `$HOME/Projects/rules_flutter`    | BCR                             | pins `rules_dart`; **currently held back** (see Phase 8) |

Paths above assume the three repos are **sibling clones under `~/Projects/`** — adjust if
yours live elsewhere. All three publish to the BCR fork `aran/bazel-central-registry` →
upstream `bazelbuild/bazel-central-registry`. A pushed `vX.Y.Z` tag triggers a release
(`.github/workflows/release.yaml`), which opens a **draft** BCR PR; marking that PR
"ready for review" triggers BCR auto-approval.

## Version policy

- `rules_dart` and `rules_dart_proto` are **version-aligned**: same number. Target =
  the next version **greater than the max latest tag across both**. Default bump =
  **patch** (`+0.0.1`); use **minor** (`+0.1.0`) for a significant feature. **Confirm
  the exact number with the user before tagging.**
- `rules_flutter` is on its **own** track and is **held back** right now (Phase 8).

## Hard guardrails (apply throughout)

- **Signing**: every commit/tag we publish MUST be signed. Never bypass signing. If
  1Password is locked and the next step publishes (push, tag push, PR), STOP and ask
  the user to unlock — do not push unsigned.
- **Trunk-based**: commit directly to `main` on the source repos; never open a PR on
  rules_dart / rules_dart_proto / rules_flutter. (BCR PRs are the publish mechanism —
  those are expected.)
- **No Co-Authored-By trailers.**
- **Don't release a downstream repo until BCR is actually serving the new rules_dart
  version** it pins — otherwise its CI can't resolve the dependency.
- Read the `folders:` and expected-failure lists out of each repo's
  `.github/workflows/ci.yaml` at runtime rather than trusting a memorized list.

---

## Phase 1 — rules_dart local readiness

Goal: `main` is green, formatted, tidy, working tree clean. From this repo:

1. **Sync & clean tree**: `git fetch origin`; on `main`, `git status` clean, not behind
   `origin/main`. Commit (signed) any release-bound changes first.
2. **Full test surface** (mirror CI). `folders` = the JSON list under `with: folders:`
   in `.github/workflows/ci.yaml` (root `.` + the `e2e/*` modules). For each:
   `cd <folder> && bazel test --test_output=errors //... || [ $? -eq 4 ]`
   (exit 4 = "no test targets", expected for build-only folders e.g. `e2e/hello_world`,
   `e2e/web_app`).
3. **Expected-failure modules** (the `expected-failure` job in `ci.yaml`):
   `e2e/pub_lock_conflict` must fail to build with `conflicting versions across lock files`;
   `e2e/analysis_failure` must fail to build with `unused_local_variable`. Confirm both.
4. **Lint**: run the **full** `pre-commit` suite, not just buildifier — CI's `pre-commit`
   job also runs `prettier` (markdown/yaml/json), `yamlfmt`, and `typos`, and buildifier
   alone will let a prettier violation through and fail CI. Prefer
   `pre-commit run --all-files` (install via `pipx install pre-commit` or
   `brew install pre-commit` if absent). If pre-commit can't be installed, at minimum run
   the same hook versions by hand on changed files, reading the pins from
   `.pre-commit-config.yaml` — e.g. `npx --yes prettier@<rev> --write <files>` and
   `bazel run //.github/workflows:buildifier.check`. The tree must be clean afterward.
5. **`bazel mod tidy`** in the root and every module dir
   (`find . -path ./bazel-* -prune -o -path ./references -prune -o -name MODULE.bazel -print | grep -v bazel-`).
   After tidying, `git status` must still be clean. If tidy changed anything, that's part
   of the release: commit it (signed) and re-run the test surface. Two fixtures can't be
   tidied standalone and will error — that's expected, ignore them: `e2e/pub_lock_conflict`
   (intentional cross-lock version conflict) and `e2e/pub_lock_cross_module/module_b` (a
   sub-module resolved only within its parent). What matters is that the tree stays clean.
6. **Locks committed**: no `MODULE.bazel.lock` dirty or untracked.

Do not proceed until everything is green and `git status` is clean.

---

## Phase 2 — Choose the target version

1. Latest tags:
   - `git -C $HOME/Projects/rules_dart tag --sort=-v:refname | head -1`
   - `git -C $HOME/Projects/rules_dart_proto fetch --tags -q && git -C $HOME/Projects/rules_dart_proto tag --sort=-v:refname | head -1`
2. `TARGET` = next version greater than the **max** of those two. Default = patch.
   Propose it (and the minor alternative) and **get the user's explicit confirmation**.
3. This `TARGET` (e.g. `v0.4.5`) is used for **both** rules_dart and rules_dart_proto.

---

## Phase 3 — Validate dependent repos against the WIP rules_dart (pre-push)

Prove the about-to-be-released rules_dart doesn't break the downstreams **before**
publishing. Use `--override_module` (the mechanism documented in `CONTRIBUTING.md`) so
their working trees stay clean. For **each** of `rules_dart_proto` and `rules_flutter`:

1. `cd` into the clone; `git fetch origin`; clean tree on `main`, up to date.
2. Determine the folder list. rules_dart_proto has a `folders:` list in `ci.yaml`;
   rules_flutter uses a **matrix** instead (root `.` plus the `e2e/*` workspaces under
   `jobs.*.strategy.matrix.workspace`) — read whichever applies. For each folder:
   ```sh
   cd <folder>
   bazel test --test_output=errors //... \
     --override_module=rules_dart=$HOME/Projects/rules_dart \
     --lockfile_mode=off \
     || [ $? -eq 4 ]
   ```
   - **`--lockfile_mode=off` is required.** Overriding `rules_dart` changes its module
     identity, so the downstream `MODULE.bazel.lock` looks stale under the default
     (strict) mode → hard error; and the default mode would **rewrite** those locks,
     dirtying the tree. `off` neither reads nor writes the lock. If an earlier run already
     dirtied locks, restore with `git checkout -- .` before continuing.
   - Pass the flags as **separate words** — don't stuff them in one shell variable, since
     zsh won't word-split it and they'll merge into the override path.
   - **rules_flutter only**: Android targets need **both** `ANDROID_HOME` and
     `ANDROID_NDK_HOME`. Exporting only the NDK is the classic mistake — `rules_android`'s
     `androidsdk` repo then generates a BUILD file with no `platform-tools/adb` target and
     `plugin_example` dies in _analysis_ with
     `no such target '...androidsdk//:platform-tools/adb'`, which looks like a rules_dart
     regression but is not. Pass them as `--repo_env` too, so a stale `androidsdk` repo
     generated under the wrong env is re-evaluated:
     ```sh
     SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"  # Linux: ~/Android/Sdk
     export ANDROID_HOME="$SDK"
     export ANDROID_NDK_HOME="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)"
     bazel test //... --repo_env=ANDROID_HOME="$SDK" --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME"
     ```
     With both set, the **whole** `plugin_example` suite passes locally on macOS, including
     `//:android_bundle_build_test` and `//:verify_android_apk_test`. Only
     `linux_bundle_build_test` / `windows_bundle_build_test` self-skip (wrong host).
3. On failure, diagnose:
   - **rules_dart regression** → fix it **in rules_dart locally**, return to Phase 1,
     re-validate. This is the main reason this phase exists.
   - **downstream-only issue** → note it; it's fixed in that repo's own release phase, not here.

This phase commits nothing to the downstreams (override is command-line only). Both must
be green against local WIP rules_dart before pushing.

---

## Phase 4 — Push rules_dart & watch CI

1. Confirm signing available. `git push origin main`.
2. Watch CI green: `gh run list --workflow=ci.yaml --branch main --limit 5`, then
   `gh run watch <run-id> --exit-status`.
3. Any failure → fix on `main` (signed), push, re-watch. Loop until green.

---

## Phase 5 — Tag the rules_dart release & watch

1. `git fetch origin`, then tag the released commit (lightweight tag on `origin/main`,
   per `CONTRIBUTING.md`):
   ```sh
   git tag $TARGET origin/main
   git push origin $TARGET
   ```
2. Watch `release.yaml` (`Release`, `Publish to BCR`, `pub-publish` jobs):
   `gh run list --workflow=release.yaml --limit 5`, then `gh run watch <run-id> --exit-status`.
3. Confirm a GitHub Release exists for `$TARGET`, the BCR publish job opened a PR, and
   pub-publish ran.

---

## Phase 6 — BCR PR → ready → merged → served (block & poll)

1. **Find the draft PR**:
   ```sh
   gh pr list --repo bazelbuild/bazel-central-registry \
     --search "rules_dart ${TARGET#v} in:title" --state open
   ```
   Verify it's the rules_dart `${TARGET#v}` PR (head from `aran/bazel-central-registry`).
2. **Mark ready for review** (triggers auto-approval):
   `gh pr ready <number> --repo bazelbuild/bazel-central-registry`.
3. **Poll until merged**: `gh pr view <number> --repo bazelbuild/bazel-central-registry
--json state,mergedAt` on an interval. If the bot/maintainer requests changes or a
   presubmit fails, surface it to the user.
   - **`buildkite/bcr-presubmit` fails fast (~45s) with zero jobs → check
     `metadata.json`, not the build.** The failure is `BcrValidationResult.FAILED: ...
invalid GitHub user ID for aran` (aran's id is `5295`). Cause: `publish-to-bcr`
     auto-populates each maintainer's `github_user_id` at publish time by resolving the
     `github` handle against the GitHub API — it does **not** come from the template.
     That lookup normally succeeds (which is why past releases shipped the field), but it
     can **transiently fail** — the publish job log shows
     `Warning: failed to fetch github user id for aran; not auto-populating ...` — leaving
     the field out. This is a flaky API call, **not** a template regression, and it is
     **unrelated** to any core-team "manual review" block on a `rules_dart` PR — don't
     conflate them. Fix in **two** places: (a) hardening, pin
     `"github_user_id": 5295` in the maintainer entry of `.bcr/metadata.template.json` so
     the value never depends on the lookup (done for all three repos as of 0.4.6 — verify
     it's still there); (b) to unblock the already-open PR whose publish run missed it,
     re-add the field to `modules/<module>/metadata.json` on the PR's fork branch
     (`aran:<module>-${TARGET}`) via the contents API, e.g.
     `gh api -X PUT repos/aran/bazel-central-registry/contents/modules/<module>/metadata.json
-f branch=<branch> -f sha=<blobsha> -f content=<base64> -f message=...`. Pushing that
     commit re-triggers presubmit; the net PR diff should then touch only `versions`.
     **Note**: adding `github_user_id` to the generated `metadata.json` is a change
     _outside the versions array_, which the BCR bot flags as a "sensitive metadata
     modification" needing manual maintainer review. Once the template carries the field,
     future releases generate it in-place and the diff stays version-only (auto-approvable).
4. **Poll until BCR serves it**: live when `modules/rules_dart/${TARGET#v}/` exists
   upstream, or a fresh module resolves `bazel_dep(name="rules_dart", version="${TARGET#v}")`.
5. **Verify pub.dev**: the `dart/runfiles` package published at `${TARGET#v}`.

Proceed to the cascade only once BCR is serving `${TARGET#v}`.

---

## Phase 7 — Cascade to rules_dart_proto (same version)

From `$HOME/Projects/rules_dart_proto`:

1. `git fetch origin`; clean tree on `main`.
2. Bump the rules_dart pin to `${TARGET#v}` in the **root** `MODULE.bazel` **and every**
   `e2e/*/MODULE.bazel`.
3. **Regenerate the locks — after removing `.bazelrc.user`.** This is the single most
   failure-prone step, and it has exactly one root cause worth remembering.

   `rules_dart_proto/.bazelrc.user` is **gitignored** (so `git status` stays clean) and
   contains `common --override_module=rules_dart=$HOME/Projects/rules_dart`. `common`
   applies to _every_ bazel command, `bazel mod tidy` included. Regenerating a lock while
   it exists corrupts that lock in two ways at once, and CI rejects it:

   - the overridden module is never fetched from the registry, so the lock omits
     `modules/rules_dart/<v>/MODULE.bazel` → `Missing checksum for registry file ...
not permitted with --lockfile_mode=error`;
   - the override changes the pub extension's owning module identity, so its
     `usagesDigest` differs → `usages of the extension '...%pub' have changed`.

   Only the **root** lock is affected — `.bazelrc` does `try-import %workspace%/.bazelrc.user`,
   and each `e2e/*` module is its own workspace. If only the root lock misbehaves, this is why.

   So: move `.bazelrc.user` aside (or regenerate from a `git ls-files`-only copy of the
   tree), then in **each** module run `bazel mod tidy --lockfile_mode=refresh` — `bazel mod
deps` does **not** re-evaluate extensions. Restore `.bazelrc.user` afterwards.

   **Verify explicitly**, for every module (root + each e2e):

   ```sh
   grep -c "modules/rules_dart/${TARGET#v}/MODULE.bazel" <module>/MODULE.bazel.lock  # must be >= 1
   bazel build //... --lockfile_mode=error                                            # must pass
   ```

   The pub `usagesDigest` is **platform-independent** — clean macOS and clean Linux
   produce byte-identical locks (verified during the 0.4.6 cascade). Do **not** spin up a
   Linux VM for this; if a lock looks platform-specific, you left `.bazelrc.user` in place.
   Commit the lock updates (signed).

4. Run the **full test surface** (its `ci.yaml` folders + `buildifier.check`) with **no
   override**, resolving the real published rules*dart. Remember this only proves \_your*
   cache resolves it — the lock verification in step 3 is what guards CI.
5. Commit (conventional message, e.g. `chore: bump rules_dart to ${TARGET#v}`), signed,
   directly to `main`. Push. Watch CI green.
6. Tag the **same** `$TARGET`: `git tag $TARGET origin/main && git push origin $TARGET`.
7. Watch `release.yaml`, then repeat **Phase 6** for the rules_dart_proto BCR PR (find →
   `gh pr ready` → poll merged → poll served). rules_dart_proto does **not** publish to pub.dev.

---

## Phase 8 — rules_flutter (HELD BACK for now)

rules_flutter is **not** ready for a public release. Do **not** tag or release it here.
It **does** track the rules_dart pin, so bump it like rules_dart_proto — just stop before
tagging.

1. It was already validated against the WIP rules_dart in **Phase 3** — sufficient for now.
2. **Bump the pin** to `${TARGET#v}` in the root `MODULE.bazel` and every `e2e/*/MODULE.bazel`
   (skip `e2e/_overlay_tests/native_assets_synthetic`, which pins `0.0.0` behind an override).
   Regenerate each lock with `bazel mod tidy --lockfile_mode=refresh`, verify with
   `--lockfile_mode=error`, commit (signed) to `main`, push, and watch CI.
3. **Pushing to `main` does not open a BCR PR.** `release.yaml` (which calls `publish.yaml`
   → BCR) fires only on a `v*.*.*` **tag push** or via `workflow_call` from `tag.yaml`.
   `tag.yaml` — a daily `smlx/ccv` cron that would otherwise auto-tag and auto-release
   conventional commits — is currently **`disabled_manually`**. Confirm before pushing:

   ```sh
   gh workflow list --all --repo aran/rules_flutter   # "Tag a Release" must be disabled
   ```

   If it is ever re-enabled, a pushed `fix:`/`feat:` commit will be auto-tagged within a
   day and a BCR PR opened. Then: close the PR, delete the tag, and re-disable the workflow.

4. **Sweep for auto-opened BCR PRs** after any push (outward-facing; confirm with the user
   before closing):
   ```sh
   gh pr list --repo bazelbuild/bazel-central-registry --search "rules_flutter in:title" --state open
   gh pr close <number> --repo bazelbuild/bazel-central-registry --comment "rules_flutter not ready for release yet"
   ```
   Leave any existing **draft** GitHub Releases (e.g. `v0.1.0`, `v0.2.0`) alone — a draft
   release does not create a git tag, and the remote currently has **no** `v*` tags.
5. When rules_flutter IS ready later: it gets its **own** next version (own track), bumps its
   rules_dart pin to the current published version, re-enables `tag.yaml` if desired, then
   follows the same per-repo flow (Phases 4–6).

---

## Done

Summarize: the version released, the rules_dart GitHub Release / BCR PR / pub.dev links,
the rules_dart_proto release, and the rules_flutter hold-back/cleanup status. Note
anything skipped (e.g. host-specific e2e modules not runnable locally).
