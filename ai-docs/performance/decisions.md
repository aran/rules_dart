# Decisions log

Newest last. "User" means the repository owner; "agent" means the reviewing
agent, which decided within the scope the user set.

## 2026-10-14

**Scope (user).** A deep performance review using approaches from other rule
sets and languages. Implementation by Haiku agents, one improvement at a time,
each pushed to `main` once confirmed good.

**Baseline first (user).** Measured on the original `main` (`3b0470c`) before
anything changed. See `results/baseline_3b0470c.json` and
`results/baseline_r2.json` (a repeat run that measured the noise).

**Leave the Gazelle plugin in the core module (user).** It does not affect
build performance enough to justify a breaking change for Gazelle users.

**Trim the SDK from test runfiles (user, after asking why tests would run SDK
commands).** No test in this repository runs `dart format`/`dart compile`.
Tests that do must declare `@rules_dart//dart` in `data`, which brings the
whole SDK. Runfiles keep `dart`, `dartvm`, the kernel-service snapshot and the
platform dills, so `Isolate.spawnUri` on `.dart` sources keeps working.

**SDK subsets fall back to the whole SDK (agent).** `compile_files` and
`runtime_files` are optional on `dart_toolchain`. A toolchain that names
neither, as rules_flutter's own may, gets `tool_files`, so other rule sets keep
working unchanged.

**Runner snapshot behind a flag (agent).** An app-JIT snapshot records the VM
build, not CPU features, so `--@rules_dart//dart:test_runner_snapshot=false`
exists for shared caches across very different CPUs. It is built only when the
exec and target SDK are the same `dart` binary. Otherwise tests run the
runner's kernel.

**`dart_format` (`bazel run`) keeps copying pub packages (agent).** It reads
its staged project from runfiles, where a relative path into `external/` does
not hold. A package split between `external/<repo>` and `bazel-out` (a
`bazel_dep` module's library with `dart_codegen` outputs) is also still copied:
two roots must be merged.

**Lockfile regression, and the extra check (agent).** The runner-snapshot
commit changed `dart/pub/private/build_content.bzl`. That moved the `pub`
extension's `bzlTransitiveDigest` and made every `MODULE.bazel.lock` stale, so
`--lockfile_mode=error` builds of this repo and its e2e workspaces failed.
Downstream users were not affected. It was missed because the sandbox ran with
`--lockfile_mode=off` (bcr.bazel.build is unreachable there). Fixed in
`4445fa1`: locks refreshed through a GitHub registry mirror, registry URLs
mapped back, every hash verified unchanged. Every change touching extension
`.bzl` files now gets a lockfile check before it lands.

**Modular kernel compilation: full module kernels, not outlines (agent).**
`kernel_worker --summary-only` is unsupported for the `vm` target: it prints
an error, exits 0, and embeds the whole platform (3.7 MB per outline). Modules
link against dependency module kernels with `--input-linked`, as
`build_vm_compilers` does. Cost: no early cutoff below the edited library.

**Modular compilation is for `dart_test` only (agent).** A `_kernel_link` tool
attr on `dart_binary` pointing at a `dart_binary` would make a cycle. A
kernel-mode `dart_binary` is rare, and the `package:test` runner is built once
per version.

**Web-only pub files: drop and retry, don't turn the feature off (agent).** Pub
packages keep `dart:js_interop`/`package:web` files next to VM code behind
conditional imports, so compiling every file of a library for the VM fails, and
`package:test` reaches `package:web`. Defaulting modular off would make it
useless. Instead, a wrapper drops the files that fail for the VM and retries,
and the test's entry module compiles from source any dropped library it
actually reaches. A real error still surfaces where the whole-program compile
would report it. This also removes the strict-deps behaviour change.

**Global `--extra_dart_defines` don't block modular mode (agent).** They are
the same for the whole build, so modules are compiled with them too. Only a
test's own `defines` fall back to whole-program.

**Analyzer summaries: opt-in flag (user).** Diagnostics come from rules_dart's
pinned `package:analyzer`, not the SDK's `dart analyze`, and the code relies on
analyzer `src/` APIs. So `//dart:analyzer_summaries` defaults to off. It can
become the default once proven.

**Lint rules in summary mode (user asked; agent chose how).** `package:analyzer`
on pub ships no lint rules, and the linter is unpublished. Vendor the SDK's
`pkg/linter/lib` from tag `3.13.5` (the toolchain default), so the lint set is
exactly what `dart analyze` runs for that SDK. Pin `analyzer` 14.1.0, the
release matching that SDK's analyzer, in a dedicated pub hub for the summary
tool only; the codegen shims stay on 13.3.0. When the default SDK moves, the
linter must be re-vendored and the pin moved.

**Linter vendored from the analyzer 13.3.0 publish commit, not tag 3.13.5
(agent).** rules_dart's `pub` extension allows one version of each package per
module, so a separate analyzer 14.1.0 hub for the summary tool is impossible
(`_fe_analyzer_shared has conflicting versions`). Moving the whole module to
14.1.0 breaks `go_router_builder` resolution and changes 97 shim dependency
versions, and the 3.13.5 linter has 135 errors against 13.3.0. The linter at
`dbeb7e1` ("Prepare to publish analyzer 13.3.0") compiles against the pinned
analyzer, and its rule set differs from SDK 3.13.5's by one rule,
`migrate_design_widgets`. Rule: the vendored linter comes from the SDK commit
that published the module's pinned `package:analyzer`, and is re-vendored when
that pin moves.

**Modular kernels: plan modules from the import graph, not from compiler errors
(agent).** The drop-and-retry wrapper worked end to end (263/263 unit tests,
all e2e passing), but it could not attribute errors to the file that caused
them, so emptied modules cascaded. `package:web` failing for the VM emptied
`package:test`, and every test then compiled `package:test` from source. Entry
modules compiled without `--exclude-non-sources` also embedded the SDK
platform (38 MB each). Replaced with the `package:build_modules` approach:

- a directive scanner reads each source's imports/exports/parts;
- conditional imports are resolved for the VM (`lib/libraries.json`);
- a file reaching a non-VM `dart:` library, or an excluded file, is excluded,
  file by file, through a per-module sidecar list.
  Remaining compile errors are real errors.

**Modular kernels measured slower; not landing (agent).** With the import-graph
planner, modular compilation was correct: 263/263 unit tests and all e2e
passing in both modes. `package:test` was 25 of 32 files, its 7 browser files
excluded, and 104 of 105 outputs were reproducible. On the benchmark it lost:

|               | Clean build                  | Leaf body edit                 |
| ------------- | ---------------------------- | ------------------------------ |
| Modular       | 40.2 s (108 module compiles) | 25.0 s (60 modules + 30 links) |
| Whole-program | 27.2 s (35 compiles)         | 23.3 s (31 compiles)           |

Linked test kernels were 2.3x larger: 30 MB vs 13 MB, because a module holds
every library of its package, and `package:analyzer`'s module alone is 18 MB.
Causes:

- no early cutoff, since the VM target has no outlines;
- every module compile reloads every dependency kernel, because
  `kernel_worker`'s incremental mode deadlocks the worker.
  The work is kept in the worktree branch, and the planner (directive scanner,
  VM conditional-import resolution) is reusable.

**Modular at library granularity (user).** Build each small library on its own
and link only what is reachable; add worker-side reuse if needed. Implemented
as follows (agent):

- one Bazel action per `dart_library`, compiling each library SCC into its own
  kernel inside a tree artifact, with an index of defined and imported URIs;
- `kernel_link` walks reachability from the test's entry and concatenates only
  the reachable SCC kernels;
- `kernel_worker`'s `--reuse-compiler-result` keeps the platform and dependency
  kernels loaded, with its stdout-corruption bug fixed at the root.
  Gates to land: linked kernel within ~10% of whole-program size, faster clean
  build and body edit, reproducible, bounded worker memory. Barrel files
  (`pkg.dart` re-exporting everything) limit the body-edit win: every importer
  of the barrel still recompiles.

**Next items (user).** Do the analyzer-only SDK file set, drop `bazel_lib`,
codegen on summaries, and multi-root in the fallback compile.

**Reproducibility is a hard requirement (user).** "We cannot have things that
are not hermetic and reproducible in the builds." The runner snapshot must be
reproducible. The audit that followed found every compiled output was
non-reproducible already, so the fix covers all compile modes (`findings.md`).
