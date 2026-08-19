/// The library analyzed by `//:analyze_ruleset_applied`. Its string literal
/// uses double quotes, which trips `prefer_single_quotes` — a
/// very_good_analysis lint that no SDK default enables. So this file is clean
/// when the ruleset is missing and dirty when it is applied, which is the
/// whole discriminator.
///
/// The obvious choice, `public_member_api_docs`, does not work here and cannot:
/// that lint asks whether a file sits in its package's public API, and answers
/// by taking the path relative to the nearest pubspec.yaml. `dart_analyze_test`
/// stages sources under `<target>.proj/src/lib/` with the synthesized pubspec
/// at `<target>.proj/`, so the relative path is `src/lib/...` and the lint
/// silently declines to fire. Pick a lint that does not gate on layout.
String label() => "double quoted";
