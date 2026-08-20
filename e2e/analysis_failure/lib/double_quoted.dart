/// The library analyzed by `//:analyze_ruleset_applied`. Its string literal
/// uses double quotes, which trips `prefer_single_quotes` — a
/// very_good_analysis lint that no SDK default enables. So this file is clean
/// when the ruleset is missing and dirty when it is applied, which is the
/// whole discriminator.
///
/// `prefer_single_quotes` deliberately does not gate on package layout, so it
/// proves ruleset delivery in isolation. The layout-gated half — a lint that
/// asks whether the file sits in its package's `lib/` — is pinned separately
/// by `//:analyze_lib_lint_applied`.
String label() => "double quoted";
