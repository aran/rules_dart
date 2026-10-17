# Benchmark and verification harness

These are Python scripts the reviewing agent ran from a scratch directory, kept
here so others can reproduce the numbers in `../results/` and `../plan.md`.
They are NOT repository tooling. `AGENTS.md` asks for repo tooling to be Dart
`dart_binary`s run with `bazel run`; porting these is what it would take to make
them part of the repository proper.

All scripts read `RULES_DART_BENCH_DIR` (default `~/rules_dart_bench`) as their
scratch root. The benchmark workspaces are generated under it.

## Bazel wrapper they expect

`suite.py`, `e2e.py` and `refresh.py` run Bazel through
`$RULES_DART_BENCH_DIR/tools/bzb` (and `refresh.py` through `tools/bzl`). Create
them for your environment. On a machine with normal network access, each can
simply `exec bazel "$@"`. In the agent's sandbox, where bcr.bazel.build,
releases.bazel.build, go.dev and codeload.github.com were unreachable, the
wrappers did the following:

- export `BAZELISK_BASE_URL=https://github.com/bazelbuild/bazel/releases/download`;
- pass `--bazelrc=<file>` with:
  - `common --registry=https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/main/`
  - `common --lockfile_mode=off` (bench and tests only; NOT `bzl`, which refreshes locks)
  - `common --override_repository=bazel_lib++toolchains+bats_toolchains=<empty dir with BUILD.bazel and REPO.bazel>`
    (bazel_lib's bats toolchain downloads from codeload, which was blocked)
  - for `bzb` only, `common --downloader_config=<file>` blocking `go.dev`,
    `golang.org` and `golang.google.cn`. Without it, `rules_go`'s `go_sdk`
    extension spends ~30 s timing out at every clean analysis.

Lockfiles generated through the mirror name raw.githubusercontent.com URLs.
`refresh.py` replays `tool/refresh_locks.dart`'s two Bazel steps. Afterwards,
replace `https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/main/`
with `https://bcr.bazel.build/` in each lock, and check that every
`registryFileHashes` value is unchanged (the mirror serves the same bytes).

## Scripts

| Script         | Use                                                                                                                                                                                                                                                                                                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gen_bench.py` | `gen_bench.py <out> <packages> <files per package> <rules_dart checkout>`: writes the synthetic workspace. Run the SDK's `dart format --language-version=3.9 packages bin` on it afterwards, or the format check fails.                                                                                                                                                   |
| `suite.py`     | `suite.py <rules_dart checkout> <label> [analysis] [build] [test] [lint]`: generates fresh workspaces, runs the scenarios and writes `results/<label>.json`. The scenarios are: re-analysis (80 packages, forced by a changed `--define`); clean build; leaf body edit; leaf API edit; null build; test run; test runfiles size; clean lint; lint after a leaf body edit. |
| `table.py`     | `table.py <label> [<label> ...]`: prints result files side by side as a Markdown table.                                                                                                                                                                                                                                                                                   |
| `bump.py`      | The body-only edit `suite.py` applies to `pkg0/lib/src/f0.dart`.                                                                                                                                                                                                                                                                                                          |
| `prof.py`      | Per-mnemonic action count and CPU totals from a `--profile` trace. Use `--noslim_profile`, or short actions are merged away.                                                                                                                                                                                                                                              |
| `starlark.py`  | Starlark function time from a trace. Calls under the profiler's threshold are not recorded at all.                                                                                                                                                                                                                                                                        |
| `e2e.py`       | `e2e.py <rules_dart checkout> <ws>[:<bazel args>] ...`: runs e2e workspaces and prints OK/FAIL with the error lines. Exit 4 counts as a pass.                                                                                                                                                                                                                             |
| `refresh.py`   | Replays `tool/refresh_locks.dart` through the `bzl` wrapper.                                                                                                                                                                                                                                                                                                              |
| `modproto.py`  | The hand-run modular-compilation prototype (`kernel_worker` per package, concatenated link) that established `../findings.md` "Modular kernel compilation".                                                                                                                                                                                                               |

## Reproducibility check

Not scripted. Run in a workspace:

```
bazel clean && bazel build //... && find -L bazel-bin -type f \( -name '*.dill' -o -name '*.jit' -o -name '*.aot' -o -name app \) -not -path '*.runfiles/*' | sort | xargs sha256sum > a.sha
bazel clean && bazel build //... && (same) > b.sha
diff a.sha b.sha
```

Then check one output with `strings -n 8 <file> | grep -c -e linux-sandbox -e /.cache/bazel -e execroot`; a hermetic output gives 0.

## `ext_exemplar` is part of verification

`e2e.py`'s default list cannot build `e2e/ext_exemplar` where go.dev is blocked:
its root `BUILD.bazel` loads `@gazelle`. `ext_exemplar.py` builds a copy with the
Gazelle targets stripped. Run it with modular compiles on and off on every change
to compilation or codegen. It is the widest codegen coverage in the repository
(json_serializable, freezed, built_value, mockito, drift, stacked, ...), and
skipping it let a modular-compile regression reach `main` (see `../in-flight.md`).
