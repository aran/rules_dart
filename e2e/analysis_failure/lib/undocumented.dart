// The library analyzed by `//:analyze_lib_lint_applied`. Its public member
// carries no doc comment, which trips `public_member_api_docs` — a lint that
// fires only when the analyzer attributes this file to a package whose `lib/`
// contains it. That attribution walks up from the file to the nearest
// pubspec.yaml, so this target is the regression pin for the staged layout:
// if the per-package stub pubspec ever goes missing, the analyzer roots the
// "package" at the project directory, this file stops being in any `lib/`,
// the lint silently declines, and this build goes green for CI to catch.
String label() => 'undocumented';
