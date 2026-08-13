"""Rules for building, testing, and analyzing Dart code.

Load this file from your BUILD files to access the following rules:

- `dart_library`: Collects Dart sources and propagates dependency information. Does not compile.
- `dart_source_set`: Assembles Dart sources (hand-written + generated) into one directory.
- `dart_binary`: Compiles a Dart application (`exe`, `aot-snapshot`, `kernel`, or `jit-snapshot`).
- `dart_test`: Runs a Dart test file using the Dart VM.
- `dart_analyze_test`: Runs `dart analyze` on a library as a build-time action.
- `dart_analysis_options`: An `analysis_options.yaml` plus the packages its `include:` directives resolve against.
- `dart_format_test`: Checks that sources match `dart format` output.
- `dart_js_binary`: Compiles a Dart web application to JavaScript.
- `dart_wasm_binary`: Compiles a Dart web application to WebAssembly.
- `dart_codegen`: Runs a Dart code generator on source files, producing generated .dart outputs.
- `dart_aggregate_codegen`: Runs a package-level aggregate code generator over all sources.
- `dart_sqlcodegen`: Like `dart_codegen` but accepts non-Dart inputs (e.g. `.drift` files).
- `dart_code_asset`: Binds a Bazel-built native dynamic library to a Dart code-asset id, for use in `dart_test`/`dart_binary` `code_assets`.
"""

load("//dart:providers.bzl", _DartCodeAssetInfo = "DartCodeAssetInfo")
load("//dart/private:dart_aggregate_codegen.bzl", _dart_aggregate_codegen = "dart_aggregate_codegen")
load("//dart/private:dart_analysis_options.bzl", _dart_analysis_options = "dart_analysis_options")
load("//dart/private:dart_analyze.bzl", _dart_analyze_test = "dart_analyze_test")
load("//dart/private:dart_binary.bzl", _dart_binary = "dart_binary")
load("//dart/private:dart_code_asset.bzl", _dart_code_asset = "dart_code_asset")
load("//dart/private:dart_codegen.bzl", _dart_codegen = "dart_codegen")
load("//dart/private:dart_format_test.bzl", _dart_format_test = "dart_format_test")
load("//dart/private:dart_library.bzl", _dart_library = "dart_library")
load("//dart/private:dart_sqlcodegen.bzl", _dart_sqlcodegen = "dart_sqlcodegen")
load("//dart/private:dart_test.bzl", _dart_test = "dart_test")
load("//dart/private:dart_web_application.bzl", _dart_js_binary = "dart_js_binary", _dart_wasm_binary = "dart_wasm_binary")
load("//dart/private:source_set.bzl", _dart_source_set = "dart_source_set")

dart_library = _dart_library
dart_source_set = _dart_source_set
dart_binary = _dart_binary
dart_test = _dart_test
dart_analyze_test = _dart_analyze_test
dart_analysis_options = _dart_analysis_options
dart_format_test = _dart_format_test
dart_js_binary = _dart_js_binary
dart_wasm_binary = _dart_wasm_binary
dart_codegen = _dart_codegen
dart_aggregate_codegen = _dart_aggregate_codegen
dart_sqlcodegen = _dart_sqlcodegen
dart_code_asset = _dart_code_asset
DartCodeAssetInfo = _DartCodeAssetInfo
