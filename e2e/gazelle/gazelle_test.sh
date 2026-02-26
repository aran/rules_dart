#!/usr/bin/env bash
set -euo pipefail

GAZELLE_BIN="${TEST_SRCDIR}/${TEST_WORKSPACE}/$1"

# Create a temporary workspace to run gazelle on
WORK="$(mktemp -d)"
trap "rm -rf ${WORK}" EXIT

# Copy source files into the temp workspace
mkdir -p "${WORK}/lib" "${WORK}/bin" "${WORK}/test"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/lib/greeter.dart" "${WORK}/lib/"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/bin/hello.dart" "${WORK}/bin/"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/bin/show_import.dart" "${WORK}/bin/"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/bin/deferred_import.dart" "${WORK}/bin/"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/test/greeter_test.dart" "${WORK}/test/"

# gazelle needs root markers
touch "${WORK}/BUILD.bazel" "${WORK}/WORKSPACE"

# Run gazelle
"${GAZELLE_BIN}" -lang dart -repo_root "${WORK}" "${WORK}"

FAIL=0

check_contains() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -q "${pattern}" "${WORK}/${file}"; then
    echo "FAIL: ${file} missing ${desc}"
    echo "  Contents:"
    sed 's/^/    /' "${WORK}/${file}"
    FAIL=1
  else
    echo "PASS: ${file} contains ${desc}"
  fi
}

# lib/ should have dart_library
check_contains "lib/BUILD.bazel" "dart_library" "dart_library rule"
check_contains "lib/BUILD.bazel" "greeter.dart" "greeter.dart in srcs"

# bin/ should have dart_binary with dep on //lib
check_contains "bin/BUILD.bazel" "dart_binary" "dart_binary rule"
check_contains "bin/BUILD.bazel" "hello.dart" "hello.dart as main"
check_contains "bin/BUILD.bazel" "show_import" "show_import rule (show modifier)"
check_contains "bin/BUILD.bazel" "deferred_import" "deferred_import rule (deferred modifier)"
check_contains "bin/BUILD.bazel" "//lib" "//lib dep for modifier imports"

# test/ should have dart_test with dep on //lib
check_contains "test/BUILD.bazel" "dart_test" "dart_test rule"
check_contains "test/BUILD.bazel" "greeter_test.dart" "greeter_test.dart as main"

if [[ ${FAIL} -ne 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
fi

echo "All Gazelle e2e tests passed"
