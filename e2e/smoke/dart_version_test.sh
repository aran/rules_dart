#!/usr/bin/env bash
set -euo pipefail

DART_BIN="${TEST_SRCDIR}/${TEST_WORKSPACE}/$1"
OUTPUT=$("${DART_BIN}" --version 2>&1)

echo "dart --version output: ${OUTPUT}"

if [[ "${OUTPUT}" != *"Dart SDK version"* ]]; then
  echo "FAIL: expected 'Dart SDK version' in output"
  exit 1
fi

echo "PASS: dart binary is runnable and reports version"
