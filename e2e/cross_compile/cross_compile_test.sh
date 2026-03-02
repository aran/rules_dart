#!/usr/bin/env bash
set -euo pipefail

# Verify the cross-compiled binary is an ELF executable (Linux), not Mach-O (macOS).
# Resolve binary path via Bazel test env vars, with dirname fallback for Windows.
if [[ -n "${TEST_SRCDIR:-}" ]] && [[ -n "${TEST_WORKSPACE:-}" ]]; then
  binary="${TEST_SRCDIR}/${TEST_WORKSPACE}/$1"
else
  binary="$(dirname "$0")/$1"
fi
file_output=$(file "$binary")

echo "file output: $file_output"

if echo "$file_output" | grep -q "ELF"; then
  echo "PASS: binary is ELF (Linux)"
  exit 0
else
  echo "FAIL: expected ELF binary, got: $file_output"
  exit 1
fi
