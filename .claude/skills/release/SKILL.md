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
   - **rules_flutter only**: Android targets need `ANDROID_NDK_HOME`. Discover an
     installed NDK rather than hardcoding a version or OS-specific path:
     ```sh
     SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"  # Linux: ~/Android/Sdk
     export ANDROID_NDK_HOME="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)"
     ```
     Targets needing a full Android SDK _platform_ (e.g. `plugin_example://:android_bundle_build_test`)
     may still fail locally with a missing `core-for-system-modules-jar` — that's an
     environment gap, not a rules*dart issue: exclude it with
     `-- //... -//:android_bundle_build_test` and record it as skipped. The iOS / macOS /
     web bundle build tests \_do* run locally and are the meaningful cross-platform coverage.
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
3. **Regenerate the locks — and verify them, because local caches will lie.** This is
   the single most failure-prone step; a green local build is **not** proof the lock is
   CI-correct. Two distinct traps, both masked by your warm caches:
   - **Missing registry checksum.** The lock must record the BCR hash for the new
     rules_dart version. Your machine has the registry file cached, so strict-mode
     builds pass locally even when the hash is absent — but clean CI fails with
     `Missing checksum for registry file .../rules_dart/<v>/MODULE.bazel not permitted
with --lockfile_mode=error`. **Verify explicitly:**
     `grep -c "modules/rules_dart/${TARGET#v}/MODULE.bazel" <module>/MODULE.bazel.lock`
     must be ≥1 for **every** module (root + each e2e).
   - **Stale extension state ("usages changed").** Bumping rules_dart changes its
     `dart/pub` extension implementation, so the lock's recorded extension result is
     stale. `bazel mod deps` resolves the module graph but does **not** re-evaluate
     extensions — use `bazel mod tidy --lockfile_mode=refresh` (the command the repo's
     `.bazelrc` documents) or an update-mode build so the pub extension is re-evaluated.
     CI rejects a stale one with `MODULE.bazel.lock is no longer up-to-date because the
usages of the extension '...%pub' have changed`.
   - **Before regenerating, drop any Phase-3 override pollution.** The `--override_module`
     runs can leave a local `rules_dart+` repo cached against the _working copy_, so the
     pub-extension hash you generate reflects the local checkout, not the published
     module. Regenerate in a clean output base (`bazel --output_base=$(mktemp -d) …`).
   - **If you cannot produce a lock that a clean build accepts** (macOS host with warm
     pub/registry/disk caches can deterministically generate a lock clean Linux CI
     rejects), regenerate it in an environment that matches CI — a clean Linux container
     with empty `PUB_CACHE` and no bazel disk cache — rather than hand-patching. Treat a
     local pass as necessary-but-not-sufficient; CI is the real verifier.
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

1. It was already validated against the WIP rules_dart in **Phase 3** — sufficient for now.
2. **Clean up the premature `v0.0.1`** (confirm with the user before executing — deleting
   remote tags and closing PRs is outward-facing and hard to reverse):
   - Delete the tag locally and on the remote, if present:
     ```sh
     git -C $HOME/Projects/rules_flutter tag -d v0.0.1 2>/dev/null || true
     git -C $HOME/Projects/rules_flutter push origin :refs/tags/v0.0.1 2>/dev/null || true
     ```
   - Leave any already-pushed GitHub releases **untagged** (don't re-tag them).
   - **Close any open rules_flutter BCR PR**:
     ```sh
     gh pr list --repo bazelbuild/bazel-central-registry --search "rules_flutter in:title" --state open
     gh pr close <number> --repo bazelbuild/bazel-central-registry --comment "rules_flutter not ready for release yet"
     ```
3. When rules_flutter IS ready later: it gets its **own** next version (own track, e.g.
   `v0.0.2`), bumps its rules_dart pin to the current published version, then follows the
   same per-repo flow (Phases 4–6).

---

## Done

Summarize: the version released, the rules_dart GitHub Release / BCR PR / pub.dev links,
the rules_dart_proto release, and the rules_flutter hold-back/cleanup status. Note
anything skipped (e.g. host-specific e2e modules not runnable locally).
