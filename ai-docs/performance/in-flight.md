# Work in flight

Snapshot as of 2026-10-15. Nothing is in flight: the review concluded with
v0.8.0 (see `README.md`). Each section below records where an item landed.
Follow-ups are the queued items in `plan.md`.

## Modular kernel compilation

Landed on `main` as `959b7b3`; see `plan.md`, `findings.md` and `for-rules-flutter.md`.

## Analyzer summaries

Landed on `main` as `398116c`; see `plan.md`.

## Reproducible outputs

Landed on `main` as `d2120e8`; see `plan.md` and `for-rules-flutter.md`.

## Analyzer-only SDK file set

Landed on `main` as `8a1e20d`; see `plan.md` and `for-rules-flutter.md`.

## Codegen on analyzer summaries (plan #12)

Landed on `main` as `4090db6` (summary-mode fixes) and `dfb6274` (codegen).
Summaries and generated files are byte-identical across install paths.

## Multi-root whole-program compile (plan #13)

Landed on `main` as `09c5905`; see `plan.md` and `for-rules-flutter.md`.

## Modular regressions (plan #14)

Fixed on `main` in `8e2e855`; see `plan.md` and `for-rules-flutter.md`. Found
through `e2e/ext_exemplar` and `//dart/ext/...`, which verification now always
runs (`harness/README.md`).

## Drop `bazel_lib` and `yaml.bzl` (plans #11, #15)

Landed on `main` as `84c8767` and `5387726`; see `plan.md` and
`for-rules-flutter.md`.

## Summaries on by default, and the pub fix it exposed

Landed on `main` as `8f3b716` (pub) and `17fab99` (summaries); see `plan.md` and
`for-rules-flutter.md`.
