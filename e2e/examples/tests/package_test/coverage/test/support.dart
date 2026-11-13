/// A file of the plain-`main()` test besides its `main`, outside the
/// package's `lib/`.
int support() {
  return '333'.length; // covered
}

/// No test calls it.
int unused() {
  return '4444'.length; // uncovered
}
