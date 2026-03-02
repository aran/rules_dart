#!/usr/bin/env bash
set -euo pipefail

# Verify the cross-compiled binary is an ELF executable (Linux), not Mach-O (macOS).
binary="${TEST_SRCDIR}/${TEST_WORKSPACE}/$1"
file_output=$(file "$binary")

echo "file output: $file_output"

if echo "$file_output" | grep -q "ELF"; then
  echo "PASS: binary is ELF (Linux)"
  exit 0
else
  echo "FAIL: expected ELF binary, got: $file_output"
  exit 1
fi
