# Plan and status

Benchmark: `harness/gen_bench.py`. 30 packages of 21 files each, where `pkgN`
depends on `pkg(N-1)` and `pkg(N-2)`, one `package:test` test per package, and
one `exe` binary. An 80-package variant measures analysis. Machine: 4-core
sandbox. Wall times vary by about ±6 s between identical runs, so action counts
and CPU totals are the steadier signal. Raw numbers are in `results/`.

## On `main`

| #   | Commit               | Change                                                                                                                                                                                                                                  | Measured effect                                                                                                          |
| --- | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| 1   | `0e3c404`            | `package_for` indexed by `lib_root`: a lookup costs path depth, not files × packages                                                                                                                                                    | Re-analysis, 80 packages: 5.97 s → 0.86 s                                                                                |
| 2   | `6d99c78`            | The format check stages only the target's own files and options, not its dependencies                                                                                                                                                   | Format checks re-run after a leaf body edit: 61 → 1                                                                      |
| 3   | `b3c8dc3`            | `DartSdkInfo.compile_files` / `runtime_files`: compile, format and test runfiles get SDK subsets                                                                                                                                        | Test runfiles: 1,073 files / 699 MB → 39 / 278 MB; clean build ~−5 s                                                     |
| 4   | `de52390`            | `package:test` runner started from an app-JIT snapshot (`//dart:test_runner_snapshot`)                                                                                                                                                  | Per test: 0.55 s → 0.25 s                                                                                                |
| 5   | `95089ce`            | Staged projects reference pub packages in place instead of copying them per target                                                                                                                                                      | Clean lint: 1,692 → 282 sandboxed actions, 1,532 → 122 copies                                                            |
| 6   | `4445fa1`            | `MODULE.bazel.lock` refresh: fixes the regression #4 introduced (see `decisions.md`)                                                                                                                                                    | `--lockfile_mode=error` builds pass again                                                                                |
| 8   | `d2120e8`            | Reproducible outputs: `gen_kernel` with `org-dartlang-bazel:///` URIs; deterministic, fixed-path snapshot training; `dart_compile_flags` routed by stage                                                                                | Every compiled output byte-identical across clean builds and install paths; build time unchanged; per test 0.55 → 0.28 s |
| 9   | `959b7b3`            | Modular `dart_test` compiles: per-SCC kernels per `dart_library`, warm `kernel_worker`, reachability-pruned link (`//dart:modular_kernel`)                                                                                              | Clean 22.1 → 19.9 s; leaf body edit 16.5 → 9.3 s; API edit 21.0 → 11.3 s; test kernel 13.0 → 4.2 MB                      |
| 7   | `398116c`            | Opt-in `//dart:analyzer_summaries`: analysis against per-library summaries; SDK linter vendored                                                                                                                                         | Leaf body edit: 61 analyses → 1 (44 s → 17 s); flag off unchanged                                                        |
| 10  | `8a1e20d`            | `DartSdkInfo.analyze_files`: analyze, fix, summary and codegen actions get the analyze subset of the SDK                                                                                                                                | `DartAnalyze` inputs on `//:bad_lib`: 1,082 → 515 (SDK 1,049 → 482)                                                      |
| 13  | `09c5905`            | Whole-program `dart_binary` / `dart_test` compile split packages in place (multi-root) instead of copying them into `.pkgsrcs` trees                                                                                                    | `e2e/codegen`, modular off: copy actions 8 → 1 (the `dart_source_set`)                                                   |
| 12  | `4090db6`, `dfb6274` | Summary mode: a `srcs_dir` library no longer claims a package it has no summary for, generated libraries are summarized (own sources staged under their own root); `dart_codegen` resolves other packages from summaries under the flag | Codegen request (warm): mockito 0.64 → 0.35 s, built_value 0.35 → 0.27 s; output byte-identical                          |
| 11  | `84c8767`            | `bazel_lib` dropped: `copy_tree`, a `dart:io` tool behind `//dart:copy_toolchain_type`, replaces `copy_to_directory`                                                                                                                    | Copy output byte-identical; ~+30 ms per copy action (Dart exe start)                                                     |
| 15  | `5387726`            | `yaml.bzl` dropped: in-repo Starlark parser for pubspec files (parity over 654 real files)                                                                                                                                              | `bazel_lib` and `yaml.bzl` gone from a downstream module graph; pub lock parse 94 → 53 ms                                |
| 14  | `8e2e855`            | Modular fixes: non-standalone libraries compile from source at the entry; duplicate sources detected per library; entry kernel linked first, so the test's own `main` runs                                                              | `ext_exemplar` builds modular; `check_dual_build_collisions_test` passes; outputs reproducible                           |
| 21  | `8f3b716`            | `pub.package` stands in for its name in every `pub.from_lock` hub and in the deps of locked packages (was dropped)                                                                                                                      | Found by making summaries the default: `e2e/pub_deps` failed to load rules_dart's own tools                              |
| 17  | `17fab99`            | `//dart:analyzer_summaries` on by default; off automatically for Flutter embedders (`sky_engine` / `_embedder.yaml`), SDKs newer than analyzer 13.3.0's language 3.13, and non-shim `generator_bin`s; split packages and parts fixed    | Lint after a leaf body edit: 61 analyses -> 1, 62 staging copies -> 2, 41.7 s -> 11.7 s; clean lint +4%                  |
| K   | `99055ee`, `72a7942` | Wrap exported toolchain/tool labels in `Label(...)` across `source_set.bzl`, `dart_kernel.bzl`, `dart_link_hook.bzl`; order `ctx.bin_dir.path` before `.` in `--multi-root` / `--filesystem-root`                                       | Cross-module `assemble_source_dir` & `dart_library` work; generated `.g.dart` shadows stale checked-in source            |
| 18  | `0f1999b`            | Export `declare_dart_sdk_toolchains` macro in `dart/toolchain.bzl` and `dart/repositories.bzl`                                                                                                                                         | Shared `compile_files` / `runtime_files` / `analyze_files` subsets for downstream SDKs (`prefix = "dart-sdk/"`)          |
| 19  | `e9451d6`            | `pub.from_lock()` fails on hosted packages without `sha256` and git packages without `resolved-ref` (`pub_lock_package` / `pub_package` reject empty `sha256`)                                                                         | Unpinned hosted or git lock entries rejected at evaluation time                                                          |
| 17b | `aa0dc5b`            | `//dart:analyzer_summaries` supports Flutter `sky_engine` `lib/_embedder.yaml` (`<name>.embedder_sdk.sum`, `--sdk-summary`) along `_sky_engine`                                                                                        | Flutter targets analyze against per-library summaries instead of falling back to full-closure source analysis            |
| 16  | `f90efba`            | Export modular kernel helpers (`DartKernelInfo`, `kernel_module_action`, `kernel_link_action`, `//dart:kernel_module`, `//dart:kernel_link`) and parameterize `target`, `platform_dill`, `extra_libraries`, `scheme`                   | Enables modular `.kmod` compilation and `org-dartlang-app:///` stable URIs in `rules_flutter`                            |

Overall: one consolidated run, baseline `3b0470c` then final `main` `b5d9f93`,
back to back on the same 4-core sandbox (`results/final_base_3b0470c.json`,
`results/final_main_b5d9f93.json`; `harness/suite.py`, `harness/table.py`).
Default flags, so modular compiles are on and analyzer summaries are off.

| Metric                                | Baseline `3b0470c`   | Final `b5d9f93`                                                |
| ------------------------------------- | -------------------- | -------------------------------------------------------------- |
| Re-analysis, 80 packages              | 6.11 s               | 0.85 s                                                         |
| Clean build wall                      | 23.6 s               | 19.0 s                                                         |
| Clean build compile CPU               | 69.7 s               | 4.8 s (+ 36 s module kernels, in workers)                      |
| Leaf body edit rebuild                | 15.7 s               | 9.2 s                                                          |
| Leaf body edit: whole compiles re-run | 31                   | 1                                                              |
| Leaf API edit rebuild                 | 15.9 s               | 8.5 s                                                          |
| Null build                            | 0.25 s               | 0.24 s                                                         |
| 30 `package:test` tests, wall         | 6.0 s                | 2.5 s                                                          |
| Per test                              | 0.64 s               | 0.24 s                                                         |
| Test runfiles                         | 1,073 files / 699 MB | 39 / 282 MB                                                    |
| Clean lint wall                       | 63.5 s               | 42.4 s                                                         |
| Clean lint: sandboxed actions         | 1,628                | 291                                                            |
| Clean lint: copy actions              | 1,471                | 122                                                            |
| Leaf body edit, lint wall             | 50.6 s               | 34.5 s                                                         |
| Leaf body edit: format checks re-run  | 61                   | 1                                                              |
| Leaf body edit: analyses re-run       | 61                   | 61 (1 with `//dart:analyzer_summaries`, measured in `398116c`) |

What the numbers leave on the table:

- Since `17fab99` (summaries on by default) a leaf body edit re-runs 1 analysis
  and 2 staging copies (41.7 s -> 11.7 s lint wall on the bench); a clean lint
  is 4% slower, the one-time summary tool build and the summaries.
- A clean lint still makes 122 staging copies (plan #20).

## In flight (see `in-flight.md`)

| #   | Item | State |
| --- | ---- | ----- |

## Queued (agreed with the user, 2026-10-14)

| #   | Item                                                                                                                              | Depends on |
| --- | --------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| 20  | Stage main-repository sources for analysis in place, cutting the 122 staging copies of a clean lint (a leaf edit re-runs only 2) | -          |

## Dropped

- Moving the Gazelle plugin (and with it `rules_go`) out of the core module.
  The user decided to leave it: it is breaking for Gazelle users, and its cost is
  one go.dev request when the `go_sdk` extension runs.
- Dropping the 54 MB kernel-service snapshot from test runfiles. It would break
  tests that spawn isolates from `.dart` source.
