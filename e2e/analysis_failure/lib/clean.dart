/// The library analyzed by `//:analyze_unresolved_ruleset`. It carries no
/// diagnostics of its own, under the SDK defaults or any ruleset: the only
/// thing that can fail that target is the unresolvable `include:`, so a green
/// run there means the analyzer stayed quiet about a broken options file.
int twice(int n) => n * 2;
