/// Deliberately trips the analyzer: the unused local variable is a
/// warning-level diagnostic, which fails the `dart_analyze` aspect.
int compute() {
  var unused = 1;
  return 2;
}
