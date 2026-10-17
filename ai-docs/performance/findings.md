# Findings

Facts established by measurement or experiment. Each says how it was
established, so it can be re-checked when the SDK or Bazel moves. Dart SDK
3.13.5, Bazel 9.2.0, Linux x64.

## Where the time went (baseline)

- **Analysis phase**: `_dart_test_impl` cost ~150 ms per test. Nearly all of it
  was `package_for`, called per transitive file and scanning every package
  (files × packages). Fixed in `0e3c404`.
- **Compiles**: each `dart_test` compiled its whole closure, `package:test`
  included: 1–3 s per test. A one-line body edit in a leaf re-ran all 31
  compiles.
- **Analysis**: `dart analyze` per target costs ~0.35 s startup plus ~1.5 ms per
  closure file. A warm analyzer cache saved under 0.1 s, because the analyzer
  re-reads and re-hashes every dependency source. Leaf edit: 61 analyses re-run.
- **Format check**: depended on the whole closure through its staged inputs, so
  it re-ran on every dependency edit. Fixed in `6d99c78`.
- **Staging copies**: each analyzed target copied every pub package in its
  closure (~50 for `package:test`). Fixed in `95089ce`.

## SDK file use (traced with `strace`)

- `dart compile exe|aot-snapshot|kernel|jit-snapshot` and `gen_kernel` open
  about 10 SDK files: `bin/dart`, `bin/dartaotruntime`, `bin/dartvm`,
  `bin/snapshots/{dartdev_aot,gen_kernel_aot,kernel-service}*`,
  `bin/utils/gen_snapshot`, `lib/_internal/vm_platform*.dill`, `version`,
  `revision`. `dart format` opens `bin/dart` and `dartdev_aot`.
- Running a kernel opens `bin/dart` and `bin/dartvm` only. The kernel-service
  snapshot is needed only to compile source at run time.
- `dart analyze` opens ~135 paths: `lib/**` sources, `analysis_server_aot`.
- The SDK is 1,049 files / 642 MB, of which `bin/` is 550 MB.

## Test runner startup

- The `package:test` runner kernel is 36 MB. The VM JIT-compiles it on every
  test: ~0.37 s.
- An app-JIT snapshot trained on one real precompiled test: ~0.12 s. Trained on
  `--help`: 0.23 s. A snapshot trained on one test works for every other test.
- The snapshot header records the VM build, `asserts`, the arch and OS, but no
  CPU features. It must be trained with `--enable-asserts`, which the launcher
  always passes.

## Reproducibility audit (2026-10-14, on `main` at `95089ce`)

Two `bazel clean` + `bazel build //...` runs of the benchmark: **all 34
compiled outputs differed.** That covers 30 test kernels, the runner kernel, its
training kernel, the runner snapshot and the AOT `exe`.

- Kernels and AOT snapshots embed `file:///root/.cache/bazel/<output-base>/sandbox/linux-sandbox/<N>/execroot/...`.
  `dart compile` resolves the package config to absolute file URIs. That is per
  sandbox and per machine, which also blocks remote-cache sharing.
- Fix in progress: `gen_kernel --filesystem-scheme org-dartlang-bazel
--filesystem-root . --filesystem-root <bin_dir>`, with a package config whose
  roots are `org-dartlang-bazel:///<path>`. Stack traces then show
  `org-dartlang-bazel:///pkg/test/x_test.dart`.
- App-JIT snapshot training, measured: three trainings in one directory gave
  three different snapshots, and `--deterministic` made them identical. The
  _length_ (not the content) of the absolute path the training runs in also
  changes the snapshot: same-length directories matched, different lengths
  didn't. The recipe is to copy the inputs into a fixed-length scratch dir
  (`/tmp/rules_dart_snapshot.XXXXXX`) and run there with relative arguments and
  a minimal explicit environment. That gave identical snapshots from exec roots
  of three different lengths. `--target_unknown_cpu` (host-independent code)
  did not change the output on this machine. It is kept for its documented
  intent; cross-CPU identity is untested.
- `--deterministic` and the fixed path cost nothing measurable at startup
  (~0.15 s either way).

## Modular kernel compilation (verified by hand)

- `dartaotruntime bin/snapshots/kernel_worker_aot.dart.snapshot` with
  `--target vm --dart-sdk-summary lib/_internal/vm_platform_strong.dill`. It
  speaks the Bazel persistent-worker protocol (`--persistent_worker`).
- Concatenating module kernels (`cat a.dill b.dill main.dill`) gives a program
  `dart` runs. Deps first, entry last.
- `--multi-root . --multi-root <bin_dir> --multi-root-scheme org-dartlang-bazel`
  with `rootUri: org-dartlang-bazel:///<lib_root>` resolves a package split
  between the source tree and `bazel-out` (generated `part`s) with no copy.
- `part` files can be passed as `--source`.
- `--summary-only` is NOT supported for `vm` (see `decisions.md`); use
  `--input-linked` with full module kernels.
- A dependent compiled with a dependency's source hidden still worked, so the
  module kernel really carries what dependents need.
- Without outlines there is no early cutoff: kernels embed bodies and offsets,
  so a body edit changes the module's bytes.
- Blocker found in implementation: pub packages with web-only files
  (`package:web`, `protobuf`'s `json_web.dart`, `web_socket_channel`'s
  `html.dart`). 9 of 97 fetched pub packages import `dart:html`, `dart:js_interop`
  or `package:web`. Hence the drop-and-retry wrapper.

## Analyzer summaries (spike, `package:analyzer` 13.3.0)

- `AnalysisContextCollectionImpl(includedPaths:, sdkPath:, packageConfigFile:,
librarySummaryPaths:)`; `collection.contexts.single.driver`;
  `driver.buildPackageBundle(uriList:)` returns `Uint8List`.
- pkg29 (21 own files, 600-file closure) analyzed against summaries: 249 ms,
  against 789 ms from source, with identical diagnostics. A planted type error
  was still reported. With dependency sources removed, analysis still worked.
- A summary build costs ~230 ms, mostly fixed. Summaries are ~39 KB.
- `collection.dispose()` throws `Bad state: Expected to link dart:core and
dart:async first` after a summary build. Don't dispose; exit.
- An SDK summary (`buildSdkSummary`) is required, or dependency summaries
  referencing `dart:io` fail with "Missing library".
- `package:analyzer` on pub contains NO lint rules. The linter is the SDK's
  unpublished `pkg/linter` (`registerLintRules()` in `lib/src/rules.dart`).
  SDK tag 3.13.5 has `pkg/analyzer` at 14.1.0-dev; published 14.1.0 matches it.
- Leaf body edit with summaries: 1 summary + 1 analysis re-run instead of 61
  analyses (44 s → 17 s).

## Environment notes (this sandbox, not the product)

- bcr.bazel.build, releases.bazel.build, go.dev, sqlite.org and codeload.github.com
  are unreachable. GitHub (releases, raw), pub.dev and storage.googleapis.com
  are reachable. See `harness/README.md` for the workaround.
- With the bench's mirror registry, `rules_go`'s `go_sdk` extension spends ~30 s
  timing out on go.dev at every clean analysis. The bench blocks go.dev in a
  downloader config to keep that out of the numbers.

## Modular at library granularity (2026-10-14)

- Per-SCC kernels in one tree artifact per `dart_library`, with an `index.json`
  of defined and imported keys. The link walks reachability from the entry.
- Bench: clean 19.4 s vs 24.7 s whole-program; leaf body edit 9.1 s vs 17.7 s
  (123 actions re-run vs 63, but each is cheap); linked `example_test` 4.2 MB vs
  13.1 MB. Whole-program kernels embed the `dart:` libraries; the modular link
  relies on the VM's platform. 334 vs 337 package libraries linked; the 3 extra
  are unreached.
- Warm `kernel_worker` with `--reuse-compiler-result
--use-incremental-compiler`: 7–11 ms per small component, vs 42–48 ms one-shot.
  Peak RSS 409 MB.
- Worker failure modes (no stdout corruption was reproducible):
  - an undeclared input is an in-band error (`Expected to get digest for
file:///...`), and the path form must match exactly;
  - a missing transitive `--input-linked` crashes the front end ("Crash when
    compiling: Null check operator ... DillLoader"), after which the child stops
    answering. The wrapper restarts it. Bazel does not expand tree artifacts in
    `WorkRequest.inputs`, so the wrapper digests those files itself.
- App-JIT snapshot bytes also depend on the absolute path of the `dart` binary
  that trains them (not just its length). Training from a copy of `dart` +
  `dartvm` at a fixed per-SDK-version path gave identical snapshots from two
  SDK locations.
