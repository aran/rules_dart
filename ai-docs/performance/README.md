# Performance review (started 2026-10-14)

A review of how fast and how hermetic rules_dart's build, test and analysis
actions are, and a series of changes landing one by one on `main`, each verified
and benchmarked before it lands.

Start here, then read in this order:

1. [`plan.md`](plan.md): every item, its status, and its measured effect.
2. [`decisions.md`](decisions.md): decisions log. Who decided what, and why.
3. [`findings.md`](findings.md): measurements and facts established along the
   way (SDK behaviour, tool limits). These are why the designs look the way they do.
4. [`in-flight.md`](in-flight.md): work that exists but is not on `main` yet.
5. [`for-rules-flutter.md`](for-rules-flutter.md): what changed, or will
   change, for rule sets built on rules_dart.
6. [`harness/`](harness/): the benchmark and verification harness, and
   [`results/`](results/), its raw output.

## Process every change follows

1. An agent implements it in its own git worktree, branched from `main`.
2. The reviewing agent reads the diff, then runs: the unit tests
   (`//dart/tests/... //dart/private/tools/... //dart/runfiles/...`), the e2e
   workspaces the change touches, the CI red-path checks from
   `.github/workflows/ci.yaml` for the area, and the benchmark suite, against
   current `main`, back to back.
3. Only then is it fast-forwarded onto `main`, with a `Changelog:` trailer per
   `AGENTS.md`.

Two checks were added to that list after something slipped through:

- **Lockfile**: any change to a `.bzl` file the `pub` or `dart` module
  extension loads changes its recorded `bzlTransitiveDigest`. Every
  `MODULE.bazel.lock` must then be refreshed, or `--lockfile_mode=error` fails.
  See `decisions.md`, 2026-10-14, "lockfile regression".
- **Reproducibility**: every new or changed build output must be byte-identical
  across two clean builds. See `findings.md`, "Reproducibility audit".

## Status: concluded 2026-10-15, released as v0.8.0

Release notes and known issues: [`release-v0.8.0.md`](release-v0.8.0.md).

The review's changes are on `main` and tagged `v0.8.0` on `Mivr/rules_dart` (the
0.7.2 release is exactly `3b0470c`, the review's baseline, so v0.8.0 is this
review). The tag is on the fork only: this environment cannot reach
`aran/rules_dart`, the BCR or pub.dev, so publishing means running the release
skill (`.claude/skills/release/SKILL.md`) from `aran/rules_dart` on a machine
with Go, signing and the BCR token.

Verified for the release (Linux, Bazel 9.2.0, Dart 3.13.5): every CI test
folder except `e2e/gazelle`, the root's 329 tests outside `//dev` and
`//gazelle`, the expected-failure job's steps, the `format-hermeticity` and
`dbg-mode` jobs, the prek hooks, `mod tidy`, and `e2e/ext_exemplar`'s build
without its Gazelle targets.

Known issues (not verifiable here; fix on a machine with Go):

- Go/Gazelle: `//gazelle/...`, `//dev/...` and `e2e/gazelle` were not built or
  tested: the Go SDK (go.dev, dl.google.com) is unreachable from the cloud
  environment. `e2e/gazelle/MODULE.bazel.lock` has a stale `pub` extension
  entry (since before 0.7.2), and the root and `e2e/ext_exemplar` locks were
  refreshed without re-evaluating Gazelle's `go_deps` extension. Refresh the locks
  (the refresh-locks skill, `tool/refresh_locks.dart`) and run `bazel test //...` in the root and `e2e/gazelle` with Go available.
- sqlite: `//dart/ext/sqlite3` and the drift targets were not built (sqlite.org
  is unreachable), and `e2e/ext_exemplar`'s tests were not run.
- Platforms: macOS and Windows were not run.

Open follow-ups are the queued items in `plan.md` (#16-#20, #17b).
