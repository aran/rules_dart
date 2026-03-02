#!/usr/bin/env bash
set -euo pipefail

DART_BIN="${TEST_SRCDIR}/${TEST_WORKSPACE}/$1"
# On Windows, the binary may have .exe extension not included in $(rootpath)
if [[ ! -x "$DART_BIN" ]] && [[ -x "${DART_BIN}.exe" ]]; then
  DART_BIN="${DART_BIN}.exe"
fi
OUTPUT=$("${DART_BIN}" --version 2>&1)

echo "dart --version output: ${OUTPUT}"

if [[ "${OUTPUT}" != *"Dart SDK version"* ]]; then
  echo "FAIL: expected 'Dart SDK version' in output"
  exit 1
fi

echo "PASS: dart binary is runnable and reports version"
