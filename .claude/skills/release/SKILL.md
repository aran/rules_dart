---
name: release
description: Drive a rules_dart release end-to-end — local readiness checks, validate dependent repos against the WIP checkout, push, watch CI, tag, mark the BCR draft PR ready, and wait for BCR + pub.dev to serve it; then cascade to rules_dart_proto (same version) and rules_flutter (own version track). Use when the user asks to cut, ship, publish, or release a new rules_dart version.
---

# Release rules_dart

A release of rules_dart cascades to two downstream repos. This runbook drives the
whole sequence. **You execute it interactively with the user in the loop** — stop
and ask whenever a gate is ambiguous or something looks off. Do not power through
failures.

## The repos

| Repo               | Local clone                       | Releases to                     | Notes                                                  |
| ------------------ | --------------------------------- | ------------------------------- | ------------------------------------------------------ |
| `rules_dart`       | `$HOME/Projects/rules_dart`       | BCR + pub.dev (`dart/runfiles`) | this repo                                              |
| `rules_dart_proto` | `$HOME/Projects/rules_dart_proto` | BCR                             | pins `rules_dart`; **version-aligned** with it         |
| `rules_flutter`    | `$HOME/Projects/rules_flutter`    | BCR                             | pins `rules_dart`; **own version track** (see Phase 8) |

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
- `rules_flutter` is on its **own** track (it started at `v0.0.1`, while rules_dart is at
  0.6.x). Its target = its own latest tag + patch by default; minor if its unreleased
  commits carry a significant feature. Confirm it with the user alongside `TARGET`.

## Hard guardrails (apply throughout)

- **Signing**: every commit and every tag we push by hand MUST be signed. Never bypass
  signing. Tags are signed annotated tags (`git tag -s`); a lightweight tag cannot carry a
  signature. Tags cut by the daily `tag.yaml` workflow are exempt: `smlx/ccv` creates and
  pushes them as `github-actions`, which holds no signing key.
- **Pushing is separate from signing**: an SSH `git push` authenticates through the
  1Password SSH agent, which can stop answering mid-session (`communication with agent
failed`). The objects are already signed, so push over HTTPS with the `gh` login instead:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' push https://github.com/aran/<repo>.git <ref>`.
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
4. **Lint**: run the **full** hook suite, not just buildifier — CI's `pre-commit`
   job also runs `prettier` (markdown/yaml/json), `yamlfmt`, and `typos`, and buildifier
   alone will let a prettier violation through and fail CI. Run
   `bazel run @multitool//tools/prek -- -C "$PWD" run --all-files` (or plain
   `prek run --all-files` if prek is installed). The tree must be clean afterward.
5. **`bazel mod tidy`** in the root and every module dir
   (`find . -path ./bazel-* -prune -o -path ./references -prune -o -name MODULE.bazel -print | grep -v bazel-`).
   After tidying, `git status` must still be clean. If tidy changed anything, that's part
   of the release: commit it (signed) and re-run the test surface. Some fixtures can't be
   tidied standalone and will error — that's expected, ignore them: `e2e/pub_lock_conflict`
   (intentional cross-lock version conflict), and every sub-module under
   `e2e/pub_lock_cross_module` (`module_b`, `module_c`) — each is resolved only within its
   parent, so standalone it fails with `rules_dart@0.0.0 not found in registries`. Expect
   that list to grow as the cross-module fixture gains sub-modules; the count is not the
   check. What matters is that the tree stays clean.
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
4. `FLUTTER_TARGET` = next patch after
   `git -C $HOME/Projects/rules_flutter fetch --tags -q && git -C $HOME/Projects/rules_flutter tag --sort=-v:refname | grep '^v' | head -1`
   (the repo also carries non-version tags such as `pre-squash-backup`; filter them out).
   Propose it with `TARGET` and get the same explicit confirmation.

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

1. Preview the release notes and show them to the user before tagging:
   `bazel run //tools/changelog -- --tag $TARGET`. They are the `Changelog:` trailers
   since the last tag (policy in `AGENTS.md`); `release_prep.sh` puts the same text in
   the GitHub release body, and `pub-publish` copies that body into
   `dart/runfiles/CHANGELOG.md`. A missing or badly worded entry is fixed by a new commit
   carrying the trailer, never by rewriting pushed history.
2. `git fetch origin`, then tag the released commit with a signed annotated tag:
   ```sh
   git tag -s -m "rules_dart $TARGET" $TARGET origin/main
   git push origin $TARGET
   ```
3. Watch `release.yaml` (`Release`, `Publish to BCR`, `pub-publish` jobs):
   `gh run list --workflow=release.yaml --limit 5`, then `gh run watch <run-id> --exit-status`.
4. Confirm a GitHub Release exists for `$TARGET`, the BCR publish job opened a PR, and
   pub-publish ran.

   - **A `publish` job that fails on `Invalid username or token` is the PAT, not the
     release.** `BCR_PUBLISH_TOKEN` is a **classic** PAT and GitHub's default expiry is 90
     days, so it dies silently between releases and takes down only the one job that
     pushes to the fork. The tell is that everything else in the run is green —
     `release / build`, `release / attest`, `release / release` and `pub-publish` all
     succeed, the registry commit is even built correctly (all files under
     `modules/<module>/$VERSION/`) — and then:

     ```
     remote: Invalid username or token. Password authentication is not supported for Git operations.
     fatal: Authentication failed for 'https://github.com/aran/bazel-central-registry.git/'
     ```

     So the GitHub Release and the pub.dev publish have already happened and must not be
     redone; only the BCR half is missing. Diagnose with `gh secret list --repo aran/<repo>`
     — the timestamp is when the PAT was _set_, and ~90 days later is when it died.

     All three repos carry the same PAT, installed in one sitting (the 2026-06-10 set is
     32 seconds apart across rules_dart / rules_dart_proto / rules_flutter), so when one
     expires **all three are dead** — fix them together rather than one release at a time.

   - **Minting the replacement**: per publish-to-bcr's README it must be a **classic** PAT
     with **`repo` and `workflow`** scopes. Not `public_repo` — and _not_ fine-grained,
     which cannot open pull requests against public repositories and only works with
     `open_pull_request: false`, which this config does not use (it opens a draft PR against
     `bazelbuild/bazel-central-registry`). Only a human in a browser can mint it; GitHub
     requires sudo-mode re-auth and deliberately will not let a token mint a token.
     **Set it to no expiration** — classic PATs allow it, and the 90-day default is the
     whole failure mode. Then:

     ```sh
     for r in rules_dart rules_dart_proto rules_flutter; do
       gh secret set BCR_PUBLISH_TOKEN --repo "aran/$r"   # paste, or pipe from `op read`
     done
     ```

   - **Recovering the release** without re-tagging: `publish.yaml` carries a
     `workflow_dispatch` with a `tag_name` input for exactly this. `gh workflow run
"Publish to BCR" --repo aran/<repo> -f tag_name=$TARGET`, then rejoin at Phase 6.

---

## Phase 6 — BCR PR → ready → merged → served (block & poll)

1. **Find the draft PR**:
   ```sh
   gh pr list --repo bazelbuild/bazel-central-registry \
     --search "rules_dart ${TARGET#v} in:title" --state open
   ```
   Verify it's the rules_dart `${TARGET#v}` PR (head from `aran/bazel-central-registry`).
   For the downstream cascades, substitute the module name and its version.
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
     the value never depends on the lookup (present in all three repos); (b) to
     unblock the already-open PR whose publish run missed it,
     re-add the field to `modules/<module>/metadata.json` on the PR's fork branch
     (`aran:<module>-${TARGET}`) via the contents API, e.g.
     `gh api -X PUT repos/aran/bazel-central-registry/contents/modules/<module>/metadata.json
-f branch=<branch> -f sha=<blobsha> -f content=<base64> -f message=...`. Pushing that
     commit re-triggers presubmit; the net PR diff should then touch only `versions`.
     **Note**: adding `github_user_id` to the generated `metadata.json` is a change
     _outside the versions array_, which the BCR bot flags as a "sensitive metadata
     modification" needing manual maintainer review.

   - **Any diff outside the versions array blocks auto-approval — including a pure key
     reorder.** Carrying `github_user_id` in the template is necessary but **not**
     sufficient: `publish-to-bcr` regenerates `metadata.json` in _template key order_,
     so if the template's maintainer keys are ordered differently from what upstream
     already stores, the PR diff shows the reorder and `bazel-io` comments "modules with
     sensitive metadata modifications (outside versions array) have been updated in this
     PR. Manual reviews are necessary." Presubmit still spawns and goes green — that is a
     **separate gate** from auto-approval, so a healthy platform matrix does not mean the
     PR will merge itself. The mismatch to watch for: upstream stores
     `… "name", "github_user_id"` while the template may list `"github_user_id"`
     before `"name"`.
     Fix: (a) reorder the maintainer keys in every `.bcr/metadata.template.json` to match
     what upstream already stores, so future releases generate a byte-identical block;
     (b) for the open PR, rewrite `modules/<module>/metadata.json` on the fork branch to
     upstream's exact bytes plus the new version, via the contents API as above. Build it
     by taking upstream's file and inserting the version string — don't re-serialize the
     JSON, or you reintroduce ordering/formatting drift. Verify with
     `gh pr diff <n>` that the only remaining hunk is the versions array.
     Note the bot does **not** retract its comment once posted; a cleaned-up diff still
     waits on a maintainer, so it is worth getting the ordering right _before_ tagging.

4. **Poll until BCR serves it — and "merged" is not "served".** The only acceptable
   proof is that a clean module actually resolves it:

   ```sh
   d=$(mktemp -d) && cd "$d" && touch BUILD.bazel
   printf 'module(name="c",version="0.0.0")\nbazel_dep(name="rules_dart",version="%s")\n' "${TARGET#v}" > MODULE.bazel
   bazel mod show_repo rules_dart   # must print a real http_archive with an integrity hash
   ```

   Do **not** accept the file existing in the registry's git repo. Measured on 0.6.3: the
   PR merged and `bcr.bazel.build/modules/rules_dart/0.6.3/{source.json,MODULE.bazel}`
   went on 404ing for a further **~30 minutes**, while
   `raw.githubusercontent.com/.../modules/rules_dart/0.6.3/source.json` returned 200
   immediately and `bcr.bazel.build/modules/rules_dart/metadata.json` listed 0.6.3 the
   whole time. So both the obvious shortcuts — check the repo, check the metadata — go
   green while Bazel still cannot fetch the module. A downstream bumped in that window
   fails with the version simply absent, which reads as a bad pin rather than a cold CDN.

   **Do not probe `bcr.bazel.build` for the module's files before the merge.** The CDN
   caches a 404 for an hour (`cache-control: max-age=3600`), so an early probe stretches
   the wait by up to an hour. Measured on 0.6.5: a probe landed about a minute before the
   upload, and the CDN served 404 for ~48 more minutes. The 0.6.3 delay above may have
   the same cause. Run the clean-module check only once the PR has merged.

5. **Verify pub.dev**: the `dart/runfiles` package published at `${TARGET#v}`.

Proceed to the cascade only once a clean module resolves `${TARGET#v}`.

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
   tree), then in **each** module run both passes, in this order:

   ```sh
   bazel mod tidy --lockfile_mode=refresh              # restores the registry hash
   bazel build --nobuild --lockfile_mode=update //...  # records the rest of the extensions
   ```

   `mod tidy` evaluates only the extensions it needs, so on its own it writes a lock
   missing entries for extensions the build reaches, which `--lockfile_mode=error`
   rejects with `The module extension '@@...' does not exist in the lockfile`.

   **Verify while `.bazelrc.user` is still parked** — restoring it first makes the root
   check fail every time, and the failure looks like a bad lock rather than a bad
   verification. For every module (root + each e2e):

   ```sh
   grep -c "modules/rules_dart/${TARGET#v}/MODULE.bazel" <module>/MODULE.bazel.lock  # must be >= 1
   bazel build //... --lockfile_mode=error                                            # must pass
   ```

   With `.bazelrc.user` in place the root fails on `the usages of the extension
'@@rules_dart+//dart/pub:extensions.bzl%pub' have changed`: the lock you just
   regenerated correctly records the _published_ module, while the restored override
   points the pub extension at the sibling checkout, so its `usagesDigest` no longer
   matches. Nothing is wrong with the lock — CI has no `.bazelrc.user`, which is exactly
   the parked state, so parked is the condition the check has to run under. Only the root
   is affected, since each `e2e/*` is its own workspace.

   Restore `.bazelrc.user` only after the verification passes.

   The pub `usagesDigest` is **platform-independent** — clean macOS and clean Linux
   produce byte-identical locks (verified during the 0.4.6 cascade). Do **not** spin up a
   Linux VM for this; if a lock looks platform-specific, you left `.bazelrc.user` in place.
   Commit the lock updates (signed).

4. Run the **full test surface** (its `ci.yaml` folders + `buildifier.check`) with **no
   override**, resolving the real published rules*dart. Remember this only proves \_your*
   cache resolves it — the lock verification in step 3 is what guards CI.
5. Commit (conventional message, e.g. `chore: bump rules_dart to ${TARGET#v}`), signed,
   directly to `main`. Push. Watch CI green.
6. Tag the **same** `$TARGET`, signed:
   `git tag -s -m "rules_dart_proto $TARGET" $TARGET origin/main && git push origin $TARGET`.
7. Watch `release.yaml`, then repeat **Phase 6** for the rules_dart_proto BCR PR (find →
   `gh pr ready` → poll merged → poll served). rules_dart_proto does **not** publish to pub.dev.

---

## Phase 8 — Cascade to rules_flutter (own version)

rules_flutter does not depend on rules_dart_proto, so this phase can run alongside
Phase 7 once Phase 6 has proven BCR serves `${TARGET#v}`. rules_flutter has its own
release skill (`$HOME/Projects/rules_flutter/.claude/skills/release/SKILL.md`); this
phase only bumps the pin and hands off to it.

1. In `$HOME/Projects/rules_flutter`: `git fetch origin`; clean tree on `main`.
2. **Bump the pin** to `${TARGET#v}` in the root `MODULE.bazel` and every `e2e/*/MODULE.bazel`
   (skip `e2e/_overlay_tests/native_assets_synthetic`, which pins `0.0.0` behind an override).
   Ignore everything under `.claude/worktrees/` — those are other sessions' checkouts.
   Commit it signed as `build: bump rules_dart to ${TARGET#v}`, the form its history uses.
3. **Run rules_flutter's release skill from its Phase 1**, with the version already
   confirmed as `FLUTTER_TARGET`. Its readiness phase parks every `.bazelrc.user`, checks
   and regenerates the locks against the published rules_dart, and runs the full test
   surface; its later phases push, tag signed, and drive the BCR PR to served. It also
   covers re-publishing a version whose BCR PR is still open.

---

## Done

Summarize: the versions released, the rules_dart GitHub Release / BCR PR / pub.dev links,
and the rules_dart_proto and rules_flutter releases and BCR PRs. Note
anything skipped (e.g. host-specific e2e modules not runnable locally).
