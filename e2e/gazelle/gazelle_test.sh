#!/usr/bin/env bash
set -euo pipefail

GAZELLE_BIN="${TEST_SRCDIR}/${TEST_WORKSPACE}/$1"

# Create a temporary workspace to run gazelle on
WORK="$(mktemp -d)"
trap "rm -rf ${WORK}" EXIT

# Copy source files into the temp workspace
mkdir -p "${WORK}/lib" "${WORK}/bin" "${WORK}/test"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/lib/greeter.dart" "${WORK}/lib/"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/lib/platform_client.dart" "${WORK}/lib/"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/lib/stub.dart" "${WORK}/lib/"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/lib/io_impl.dart" "${WORK}/lib/"
cp "${TEST_SRCDIR}/${TEST_WORKSPACE}/lib/web_impl.dart" "${WORK}/lib/"
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

# lib/ should have dart_library with all srcs
check_contains "lib/BUILD.bazel" "dart_library" "dart_library rule"
check_contains "lib/BUILD.bazel" "greeter.dart" "greeter.dart in srcs"
check_contains "lib/BUILD.bazel" "platform_client.dart" "platform_client.dart in srcs"
check_contains "lib/BUILD.bazel" "stub.dart" "stub.dart in srcs"
check_contains "lib/BUILD.bazel" "io_impl.dart" "io_impl.dart in srcs"
check_contains "lib/BUILD.bazel" "web_impl.dart" "web_impl.dart in srcs"

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

echo "--- Basic tests passed ---"

# ============================================================
# Test dart_pub_deps_repo directive
# ============================================================
WORK2="$(mktemp -d)"
trap "rm -rf ${WORK} ${WORK2}" EXIT

mkdir -p "${WORK2}/lib"
touch "${WORK2}/WORKSPACE"

# Root BUILD with dart_pub_deps_repo directive
cat > "${WORK2}/BUILD.bazel" <<'EOF'
# gazelle:dart_pub_deps_repo pub_deps
EOF

# Dart file that imports external packages
cat > "${WORK2}/lib/app.dart" <<'EOF'
import 'package:shelf/shelf.dart';
import 'package:path/path.dart';
void main() {}
EOF
touch "${WORK2}/lib/BUILD.bazel"

"${GAZELLE_BIN}" -lang dart -repo_root "${WORK2}" "${WORK2}"

check_contains2() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -q "${pattern}" "${WORK2}/${file}"; then
    echo "FAIL: ${file} missing ${desc}"
    echo "  Contents:"
    sed 's/^/    /' "${WORK2}/${file}"
    FAIL=1
  else
    echo "PASS: ${file} contains ${desc}"
  fi
}

# lib/ deps should use @pub_deps// labels
check_contains2 "lib/BUILD.bazel" "@pub_deps//:shelf" "@pub_deps//:shelf dep"
check_contains2 "lib/BUILD.bazel" "@pub_deps//:path" "@pub_deps//:path dep"

# ============================================================
# Test dart_package_name directive emits package_name attr
# ============================================================
WORK3="$(mktemp -d)"
trap "rm -rf ${WORK} ${WORK2} ${WORK3}" EXIT

mkdir -p "${WORK3}/lib"
touch "${WORK3}/WORKSPACE" "${WORK3}/BUILD.bazel"

cat > "${WORK3}/lib/BUILD.bazel" <<'EOF'
# gazelle:dart_package_name my_app
EOF

cat > "${WORK3}/lib/app.dart" <<'EOF'
String hello() => 'hello';
EOF

"${GAZELLE_BIN}" -lang dart -repo_root "${WORK3}" "${WORK3}"

check_contains3() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -q "${pattern}" "${WORK3}/${file}"; then
    echo "FAIL: ${file} missing ${desc}"
    echo "  Contents:"
    sed 's/^/    /' "${WORK3}/${file}"
    FAIL=1
  else
    echo "PASS: ${file} contains ${desc}"
  fi
}

# dart_package_name should set both name and package_name
check_contains3 "lib/BUILD.bazel" 'name = "my_app"' "name = my_app"
check_contains3 "lib/BUILD.bazel" 'package_name = "my_app"' "package_name = my_app"

# ============================================================
# Test X/lib/ auto-detection of package name
# ============================================================
WORK4="$(mktemp -d)"
trap "rm -rf ${WORK} ${WORK2} ${WORK3} ${WORK4}" EXIT

mkdir -p "${WORK4}/mylib/lib"
touch "${WORK4}/WORKSPACE" "${WORK4}/BUILD.bazel" "${WORK4}/mylib/lib/BUILD.bazel"

cat > "${WORK4}/mylib/lib/mylib.dart" <<'EOF'
String greet() => 'hi';
EOF

"${GAZELLE_BIN}" -lang dart -repo_root "${WORK4}" "${WORK4}"

check_contains4() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -q "${pattern}" "${WORK4}/${file}"; then
    echo "FAIL: ${file} missing ${desc}"
    echo "  Contents:"
    sed 's/^/    /' "${WORK4}/${file}"
    FAIL=1
  else
    echo "PASS: ${file} contains ${desc}"
  fi
}

# X/lib/ should auto-detect name from parent dir
check_contains4 "mylib/lib/BUILD.bazel" 'name = "mylib"' "name = mylib"
check_contains4 "mylib/lib/BUILD.bazel" 'package_name = "mylib"' "package_name = mylib"

if [[ ${FAIL} -ne 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
fi

echo "All Gazelle e2e tests passed"
