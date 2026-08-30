/// Prints a compile-time environment declaration, so a run of the compiled
/// binary observes whether `defines` survived the compile pipeline. `const`
/// matters: that is what forces resolution during constant evaluation, which
/// is the stage a precompiled `.dill` has already passed.
void main() {
  print(const String.fromEnvironment('CHANNEL', defaultValue: 'UNSET'));
}
