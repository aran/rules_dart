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

# The gazelle binary path is passed as the first argument (rlocationpath relative)
GAZELLE_BIN="$(rlocation "$1")"

# Create a temporary workspace to run gazelle on
WORK="$(mktemp -d)"
trap "rm -rf ${WORK}" EXIT

# Set up Dart source files in conventional structure
mkdir -p "${WORK}/lib" "${WORK}/bin" "${WORK}/test"

cat > "${WORK}/lib/greeter.dart" << 'DART'
class Greeter {
  final String name;
  Greeter(this.name);
  String greet() => 'Hello, $name!';
}
DART

cat > "${WORK}/lib/formatter.dart" << 'DART'
String formatGreeting(String greeting) {
  return '*** $greeting ***';
}
DART

cat > "${WORK}/bin/hello.dart" << 'DART'
import 'package:lib/greeter.dart';

void main() {
  final greeter = Greeter('World');
  print(greeter.greet());
}
DART

cat > "${WORK}/test/greeter_test.dart" << 'DART'
import 'package:lib/greeter.dart';

void main() {
  final greeter = Greeter('Test');
  assert(greeter.greet() == 'Hello, Test!');
}
DART

# gazelle needs a root marker
touch "${WORK}/BUILD.bazel"
touch "${WORK}/WORKSPACE"

# Run gazelle with -repo_root so it treats the temp dir as a workspace
"${GAZELLE_BIN}" -lang dart -repo_root "${WORK}" "${WORK}"

FAIL=0

check_file() {
  local file="$1"
  if [[ ! -f "${WORK}/${file}" ]]; then
    echo "FAIL: ${file} was not generated"
    FAIL=1
    return 1
  fi
  echo "PASS: ${file} generated"
  return 0
}

check_contains() {
  local file="$1"
  local pattern="$2"
  local desc="$3"
  if ! grep -q "${pattern}" "${WORK}/${file}"; then
    echo "FAIL: ${file} does not contain ${desc}"
    echo "  Contents:"
    sed 's/^/    /' "${WORK}/${file}"
    FAIL=1
    return 1
  fi
  echo "PASS: ${file} contains ${desc}"
  return 0
}

echo "=== Checking generated BUILD files ==="

# lib/ should have dart_library with both source files
check_file "lib/BUILD.bazel"
check_contains "lib/BUILD.bazel" "dart_library" "dart_library rule"
check_contains "lib/BUILD.bazel" "greeter.dart" "greeter.dart in srcs"
check_contains "lib/BUILD.bazel" "formatter.dart" "formatter.dart in srcs"
check_contains "lib/BUILD.bazel" "visibility" "visibility attribute"

# bin/ should have dart_binary with dep on //lib (from package:lib import)
check_file "bin/BUILD.bazel"
check_contains "bin/BUILD.bazel" "dart_binary" "dart_binary rule"
check_contains "bin/BUILD.bazel" "hello.dart" "hello.dart as main"
check_contains "bin/BUILD.bazel" "//lib" "dep on //lib from package:lib import"

# test/ should have dart_test with dep on //lib
check_file "test/BUILD.bazel"
check_contains "test/BUILD.bazel" "dart_test" "dart_test rule"
check_contains "test/BUILD.bazel" "greeter_test.dart" "greeter_test.dart as main"
check_contains "test/BUILD.bazel" "//lib" "dep on //lib from package:lib import"

echo ""
echo "=== Generated BUILD files ==="
for f in lib/BUILD.bazel bin/BUILD.bazel test/BUILD.bazel; do
  if [[ -f "${WORK}/${f}" ]]; then
    echo "--- ${f} ---"
    cat "${WORK}/${f}"
    echo ""
  fi
done

if [[ ${FAIL} -ne 0 ]]; then
  echo "=== SOME TESTS FAILED ==="
  exit 1
fi

echo "=== All Gazelle tests passed ==="
