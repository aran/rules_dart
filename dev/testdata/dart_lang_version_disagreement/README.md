# dart_lang_version_disagreement

Directives that state a package name and language version other than the ones
the package's `pubspec.yaml` states. Gazelle reports every disagreement, naming
both values and where each is stated, then fails without writing a BUILD file.
