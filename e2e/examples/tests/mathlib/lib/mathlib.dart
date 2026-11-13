/// Returns `n!`; throws [ArgumentError] for negative [n].
int factorial(int n) {
  if (n < 0) throw ArgumentError('Negative number: $n');
  if (n <= 1) return 1;
  return n * factorial(n - 1);
}

/// Whether [n] is prime.
bool isPrime(int n) {
  if (n < 2) return false;
  for (var i = 2; i * i <= n; i++) {
    if (n % i == 0) return false;
  }
  return true;
}
