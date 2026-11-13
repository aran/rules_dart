/// The library under a broken options file. It carries no diagnostics of its
/// own, under the SDK defaults or any ruleset: the only thing that can fail its
/// analysis is the unresolvable `include:`, so a green run means the analyzer
/// stayed quiet about a broken options file.
int twice(int n) => n * 2;
