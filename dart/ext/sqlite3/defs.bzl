"""Convenience accessor for the sqlite3 code asset.

Usage in a `dart_test` / `dart_binary` that uses `package:sqlite3` (directly
or transitively, e.g. via `drift`'s `NativeDatabase`):

    load("@rules_dart//dart/ext/sqlite3:defs.bzl", "sqlite3_code_asset")

    dart_test(
        name = "db_test",
        main = "test/db_test.dart",   # plain NativeDatabase.memory(), no FFI ceremony
        code_assets = [sqlite3_code_asset()],
        deps = [...],
    )
"""

def sqlite3_code_asset():
    """Returns the label of the rules_dart-provided sqlite3 code asset."""
    return "@rules_dart//dart/ext/sqlite3:code_asset"
