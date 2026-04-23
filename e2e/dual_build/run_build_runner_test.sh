#!/usr/bin/env bash
# `build_runner` runs cleanly next to Bazel scaffolding (BUILD.bazel,
# MODULE.bazel, `bazel-*` symlinks). Non-hermetic: needs network for
# `dart pub get`; the BUILD target is `manual`-tagged accordingly.

set -euo pipefail

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail
f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }
f=
set -e
# --- end runfiles.bash initialization v3 ---

dart_rlocation="$1"
dart_bin="$(rlocation "$dart_rlocation")"
if [[ -z "$dart_bin" || ! -x "$dart_bin" ]]; then
  echo "FAIL: dart binary not found at rlocation $dart_rlocation" >&2
  exit 1
fi

pubspec="$(rlocation _main/fixture_pubspec.yaml)"
user_src="$(rlocation _main/fixture_lib/user.dart)"
if [[ ! -f "$pubspec" || ! -f "$user_src" ]]; then
  echo "FAIL: fixture files missing in runfiles" >&2
  echo "  pubspec: $pubspec" >&2
  echo "  user_src: $user_src" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/lib"
cp "$pubspec" "$tmp/pubspec.yaml"
cp "$user_src" "$tmp/lib/user.dart"

# Fake Bazel scaffolding at package root — `package:build`'s asset walker
# only descends into lib/, test/, bin/, web/, tool/, so these are ignored.
cat >"$tmp/BUILD.bazel" <<'EOF'
load("@rules_dart//dart/ext/json_serializable:defs.bzl", "json_serializable_library")

json_serializable_library(
    name = "user",
    srcs = ["lib/user.dart"],
    package_name = "dual_build_fixture",
    language_version = "3.11",
    visibility = ["//visibility:public"],
)
EOF

cat >"$tmp/MODULE.bazel" <<'EOF'
module(name = "dual_build_fixture")
bazel_dep(name = "rules_dart", version = "0.0.0")
EOF

# Bazel's convenience symlinks, pointed at /nonexistent to prove
# `build_runner` doesn't follow or stat them.
ln -s /nonexistent "$tmp/bazel-bin"
ln -s /nonexistent "$tmp/bazel-out"
ln -s /nonexistent "$tmp/bazel-testlogs"
ln -s /nonexistent "$tmp/bazel-dual_build_fixture"

# Scope pub cache to the tempdir so the test is self-contained and leaves
# no trace on the host filesystem.
export PUB_CACHE="$tmp/.pub-cache"
export HOME="$tmp"

(
  cd "$tmp"
  "$dart_bin" pub get
  "$dart_bin" run build_runner build --delete-conflicting-outputs
)

if [[ ! -s "$tmp/lib/user.g.dart" ]]; then
  echo "FAIL: build_runner did not produce lib/user.g.dart (or file is empty)" >&2
  ls -la "$tmp/lib/" >&2 || true
  exit 1
fi

# Sanity grep: must contain a real generator output, not just a stub.
if ! grep -q '_\$UserToJson' "$tmp/lib/user.g.dart"; then
  echo "FAIL: lib/user.g.dart missing expected _\$UserToJson generator output" >&2
  cat "$tmp/lib/user.g.dart" >&2 || true
  exit 1
fi

echo "PASS: build_runner produced lib/user.g.dart with expected content in a Bazel-scaffolded workspace"
