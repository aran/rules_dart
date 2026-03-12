"""Rules for building, testing, and analyzing Dart code.

Load this file from your BUILD files to access the following rules:

- `dart_library`: Collects Dart sources and propagates dependency information. Does not compile.
- `dart_binary`: Compiles a Dart application (`exe`, `aot-snapshot`, `kernel`, or `jit-snapshot`).
- `dart_test`: Runs a Dart test file using the Dart VM.
- `dart_analyze_test`: Runs `dart analyze` on a library as a build-time action.
- `dart_format_test`: Checks that sources match `dart format` output.
- `dart_js_binary`: Compiles a Dart web application to JavaScript.
- `dart_wasm_binary`: Compiles a Dart web application to WebAssembly.
- `dart_codegen`: Runs a Dart code generator on source files, producing generated .dart outputs.
- `dart_aggregate_codegen`: Runs a package-level aggregate code generator over all sources.
"""

load("//dart/private:dart_aggregate_codegen.bzl", _dart_aggregate_codegen = "dart_aggregate_codegen")
load("//dart/private:dart_analyze.bzl", _dart_analyze_test = "dart_analyze_test")
load("//dart/private:dart_binary.bzl", _dart_binary = "dart_binary")
load("//dart/private:dart_codegen.bzl", _dart_codegen = "dart_codegen")
load("//dart/private:dart_format_test.bzl", _dart_format_test = "dart_format_test")
load("//dart/private:dart_library.bzl", _dart_library = "dart_library")
load("//dart/private:dart_test.bzl", _dart_test = "dart_test")
load("//dart/private:dart_web_application.bzl", _dart_js_binary = "dart_js_binary", _dart_wasm_binary = "dart_wasm_binary")

dart_library = _dart_library
dart_binary = _dart_binary
dart_test = _dart_test
dart_analyze_test = _dart_analyze_test
dart_format_test = _dart_format_test
dart_js_binary = _dart_js_binary
dart_wasm_binary = _dart_wasm_binary
dart_codegen = _dart_codegen
dart_aggregate_codegen = _dart_aggregate_codegen
