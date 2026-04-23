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

GAZELLE_BIN="$(rlocation "$1")"

# Create a temporary workspace to run gazelle on
WORK="$(mktemp -d)"
trap "rm -rf ${WORK}" EXIT

# Copy source files into the temp workspace
mkdir -p "${WORK}/lib" "${WORK}/bin" "${WORK}/test"
cp "$(rlocation "${TEST_WORKSPACE}/lib/greeter.dart")" "${WORK}/lib/"
cp "$(rlocation "${TEST_WORKSPACE}/lib/platform_client.dart")" "${WORK}/lib/"
cp "$(rlocation "${TEST_WORKSPACE}/lib/stub.dart")" "${WORK}/lib/"
cp "$(rlocation "${TEST_WORKSPACE}/lib/io_impl.dart")" "${WORK}/lib/"
cp "$(rlocation "${TEST_WORKSPACE}/lib/web_impl.dart")" "${WORK}/lib/"
cp "$(rlocation "${TEST_WORKSPACE}/bin/hello.dart")" "${WORK}/bin/"
cp "$(rlocation "${TEST_WORKSPACE}/bin/show_import.dart")" "${WORK}/bin/"
cp "$(rlocation "${TEST_WORKSPACE}/bin/deferred_import.dart")" "${WORK}/bin/"
cp "$(rlocation "${TEST_WORKSPACE}/test/greeter_test.dart")" "${WORK}/test/"

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
# Test pubspec.yaml auto-detection of package name
# ============================================================
WORK4="$(mktemp -d)"
trap "rm -rf ${WORK} ${WORK2} ${WORK3} ${WORK4}" EXIT

mkdir -p "${WORK4}/lib"
touch "${WORK4}/WORKSPACE" "${WORK4}/BUILD.bazel" "${WORK4}/lib/BUILD.bazel"

cat > "${WORK4}/pubspec.yaml" <<'EOF'
name: my_server
EOF

cat > "${WORK4}/lib/app.dart" <<'EOF'
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

# pubspec.yaml name should be used for dart_library
check_contains4 "lib/BUILD.bazel" 'name = "my_server"' "name = my_server"
check_contains4 "lib/BUILD.bazel" 'package_name = "my_server"' "package_name = my_server"

# ============================================================
# Test gazelle:resolve directive override
# ============================================================
WORK5="$(mktemp -d)"
trap "rm -rf ${WORK} ${WORK2} ${WORK3} ${WORK4} ${WORK5}" EXIT

mkdir -p "${WORK5}/lib"
touch "${WORK5}/WORKSPACE"

# Root BUILD with gazelle:resolve override for shelf
cat > "${WORK5}/BUILD.bazel" <<'EOF'
# gazelle:resolve dart shelf //third_party:shelf_custom
EOF

cat > "${WORK5}/lib/app.dart" <<'EOF'
import 'package:shelf/shelf.dart';
import 'package:path/path.dart';
void main() {}
EOF
touch "${WORK5}/lib/BUILD.bazel"

"${GAZELLE_BIN}" -lang dart -repo_root "${WORK5}" "${WORK5}"

check_contains5() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -q "${pattern}" "${WORK5}/${file}"; then
    echo "FAIL: ${file} missing ${desc}"
    echo "  Contents:"
    sed 's/^/    /' "${WORK5}/${file}"
    FAIL=1
  else
    echo "PASS: ${file} contains ${desc}"
  fi
}

# shelf should resolve to the override label
check_contains5 "lib/BUILD.bazel" "//third_party:shelf_custom" "gazelle:resolve override for shelf"
# path should still use default external resolution (no override)
check_contains5 "lib/BUILD.bazel" "@path" "default resolution for path"

# ============================================================
# Test annotation-driven emission: @JsonSerializable -> SharedPart + combine
# ============================================================
WORK6="$(mktemp -d)"
trap "rm -rf ${WORK} ${WORK2} ${WORK3} ${WORK4} ${WORK5} ${WORK6}" EXIT

mkdir -p "${WORK6}/lib"
touch "${WORK6}/WORKSPACE" "${WORK6}/BUILD.bazel"

cat > "${WORK6}/pubspec.yaml" <<'EOF'
name: my_models
environment:
  sdk: ^3.11.0
EOF

cat > "${WORK6}/BUILD.bazel" <<'EOF'
# gazelle:dart_pub_deps_repo pub_deps
EOF

cat > "${WORK6}/lib/user.dart" <<'EOF'
import 'package:json_annotation/json_annotation.dart';
part 'user.g.dart';
@JsonSerializable()
class User {
  User({required this.id, required this.name});
  final int id;
  final String name;
}
EOF

"${GAZELLE_BIN}" -lang dart -repo_root "${WORK6}" "${WORK6}"

check_contains6() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -q "${pattern}" "${WORK6}/${file}"; then
    echo "FAIL: ${file} missing ${desc}"
    echo "  Contents:"
    sed 's/^/    /' "${WORK6}/${file}"
    FAIL=1
  else
    echo "PASS: ${file} contains ${desc}"
  fi
}

# Single-annotation files emit the convenience macro, not the primitive
# chain. The macro (json_serializable_library) internally wires the shard +
# combining stages; we only see the one macro call in the BUILD.
check_contains6 "lib/BUILD.bazel" "json_serializable_library(" \
  "json_serializable_library macro call"
check_contains6 "lib/BUILD.bazel" 'name = "user"' "macro target name"
check_contains6 "lib/BUILD.bazel" 'package_name = "my_models"' \
  "package_name propagated to macro"
check_contains6 "lib/BUILD.bazel" 'language_version = ' \
  "language_version propagated to macro"
check_contains6 "lib/BUILD.bazel" \
  'load("@rules_dart//dart/ext/json_serializable:defs.bzl"' \
  "json_serializable_library load"
# Primitive chain internals must NOT appear for a single-annotation file.
if grep -q "_user_json_serializable_gen\|_user_combined\|combining_shim:bin" "${WORK6}/lib/BUILD.bazel"; then
  echo "FAIL: single-annotation file emitted primitive chain instead of macro"
  FAIL=1
else
  echo "PASS: primitive chain suppressed (macro used)"
fi

# ============================================================
# Test multi-annotation cascade: @Freezed + @JsonSerializable
# ============================================================
WORK7="$(mktemp -d)"
trap "rm -rf ${WORK} ${WORK2} ${WORK3} ${WORK4} ${WORK5} ${WORK6} ${WORK7}" EXIT

mkdir -p "${WORK7}/lib"
touch "${WORK7}/WORKSPACE" "${WORK7}/BUILD.bazel"

cat > "${WORK7}/pubspec.yaml" <<'EOF'
name: my_events
EOF

cat > "${WORK7}/BUILD.bazel" <<'EOF'
# gazelle:dart_pub_deps_repo pub_deps
EOF

cat > "${WORK7}/lib/event.dart" <<'EOF'
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:json_annotation/json_annotation.dart';
part 'event.freezed.dart';
part 'event.g.dart';
@Freezed()
@JsonSerializable()
abstract class Event with _$Event {
  const factory Event({required String type, required int sequence}) = _Event;
  factory Event.fromJson(Map<String, Object?> json) => _$EventFromJson(json);
}
EOF

"${GAZELLE_BIN}" -lang dart -repo_root "${WORK7}" "${WORK7}"

check_contains7() {
  local file="$1" pattern="$2" desc="$3"
  if ! grep -q "${pattern}" "${WORK7}/${file}"; then
    echo "FAIL: ${file} missing ${desc}"
    echo "  Contents:"
    sed 's/^/    /' "${WORK7}/${file}"
    FAIL=1
  else
    echo "PASS: ${file} contains ${desc}"
  fi
}

# Cascade should run Freezed (PartBuilder) BEFORE JsonSerializable (SharedPart),
# then a combining stage on the JsonSerializable shard.
check_contains7 "lib/BUILD.bazel" "_event_freezed_gen" "freezed stage"
check_contains7 "lib/BUILD.bazel" "_event_json_serializable_gen" "json shard stage"
check_contains7 "lib/BUILD.bazel" "_event_combined" "combining stage"

# ============================================================
# Test generated files are suppressed
# ============================================================
WORK8="$(mktemp -d)"
trap "rm -rf ${WORK} ${WORK2} ${WORK3} ${WORK4} ${WORK5} ${WORK6} ${WORK7} ${WORK8}" EXIT

mkdir -p "${WORK8}/lib"
touch "${WORK8}/WORKSPACE" "${WORK8}/BUILD.bazel"

cat > "${WORK8}/pubspec.yaml" <<'EOF'
name: my_skip
EOF

# real source
cat > "${WORK8}/lib/keep.dart" << 'EOF'
class Keep {}
EOF
# generated lookalikes that should be skipped
echo 'class GoneG {}' > "${WORK8}/lib/keep.g.dart"
echo 'class GoneFreezed {}' > "${WORK8}/lib/keep.freezed.dart"
echo 'class GoneMocks {}' > "${WORK8}/lib/keep.mocks.dart"

"${GAZELLE_BIN}" -lang dart -repo_root "${WORK8}" "${WORK8}"

if grep -q "keep.g.dart\|keep.freezed.dart\|keep.mocks.dart" "${WORK8}/lib/BUILD.bazel"; then
  echo "FAIL: lib/BUILD.bazel mentions a generated-file extension"
  sed 's/^/    /' "${WORK8}/lib/BUILD.bazel"
  FAIL=1
else
  echo "PASS: generated files (.g.dart/.freezed.dart/.mocks.dart) suppressed"
fi
if ! grep -q "keep.dart" "${WORK8}/lib/BUILD.bazel"; then
  echo "FAIL: lib/BUILD.bazel missing keep.dart (the real source)"
  FAIL=1
else
  echo "PASS: real source kept"
fi

if [[ ${FAIL} -ne 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
fi

echo "All Gazelle e2e tests passed"
