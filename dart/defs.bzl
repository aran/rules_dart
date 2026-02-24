"Public API re-exports"

load("//dart/private:dart_analyze.bzl", _dart_analyze_test = "dart_analyze_test")
load("//dart/private:dart_binary.bzl", _dart_binary = "dart_binary")
load("//dart/private:dart_format_test.bzl", _dart_format_test = "dart_format_test")
load("//dart/private:dart_library.bzl", _dart_library = "dart_library")
load("//dart/private:dart_test.bzl", _dart_test = "dart_test")
load("//dart/private:dart_web_application.bzl", _dart_web_application = "dart_web_application")

dart_library = _dart_library
dart_binary = _dart_binary
dart_test = _dart_test
dart_analyze_test = _dart_analyze_test
dart_format_test = _dart_format_test
dart_web_application = _dart_web_application
