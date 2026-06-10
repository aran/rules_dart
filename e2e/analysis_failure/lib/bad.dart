/// Deliberately trips the analyzer: the unused local variable is a
/// warning-level diagnostic, fatal under the rule's --fatal-infos run.
int compute() {
  var unused = 1;
  return 2;
}
