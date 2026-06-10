# dart_lang_version_pubspec

Fixture guarding pubspec-derived `language_version` on the
multi-annotation codegen path. With no
`# gazelle:dart_language_version` directive, `emitCodegenStages` must
fall back to the nearest pubspec.yaml's `environment.sdk` lower bound
(here `^3.11.0` → `"3.11"`) — same walk-up the macro fast path already
does via `resolvedLanguageVersion`. `user.dart` (single annotation)
pins the macro-path behavior; `event.dart` (freezed +
json_serializable) exercises the emitted `dart_codegen` stages and
wrapping `dart_library`.
