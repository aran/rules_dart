# dart_lang_version_pubspec

Fixture guarding pubspec-derived `language_version` on the
multi-annotation codegen path. With no
`# gazelle:dart_language_version` directive, `emitCodegen` must
fall back to the package root's pubspec.yaml's `environment.sdk` lower bound
(here `^3.11.0` → `"3.11"`) — the same lookup the macro fast path
does via `resolvedLanguageVersion`. `user.dart` (single annotation)
pins the macro-path behavior; `event.dart` (freezed +
json_serializable) exercises the emitted `dart_codegen` stages and
the package's `dart_library`.
