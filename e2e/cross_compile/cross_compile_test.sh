#!/usr/bin/env bash
# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

# Verify the cross-compiled binary is an ELF executable (Linux), not Mach-O (macOS).
binary="$(rlocation "$1")"
file_output=$(file "$binary")

echo "file output: $file_output"

if echo "$file_output" | grep -q "ELF"; then
  echo "PASS: binary is ELF (Linux)"
  exit 0
else
  echo "FAIL: expected ELF binary, got: $file_output"
  exit 1
fi
