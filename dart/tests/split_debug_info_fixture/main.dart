// Prints its own stack trace: symbolic with the debugging information in the
// executable, addresses without it.
void main() => print(StackTrace.current);
