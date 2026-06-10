# dart_lang_version_absent

Fixture pinning Gazelle's output when no language version is derivable:
no `# gazelle:dart_language_version` directive and no pubspec.yaml. The
emitted macro call must simply omit `language_version` — which requires
the builder macros to accept its absence (the rule layer applies a safe
default).
