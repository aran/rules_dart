/// Reached only through `dart_analysis_test`: its target is tagged `manual`.
int manualBad() {
  return 1;
  print('unreachable');
}
