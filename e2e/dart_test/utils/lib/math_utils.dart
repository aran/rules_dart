int factorial(int n) {
  if (n <= 1) return 1;
  return n * factorial(n - 1);
}

bool isPrime(int n) {
  if (n < 2) return false;
  for (int i = 2; i * i <= n; i++) {
    if (n % i == 0) return false;
  }
  return true;
}
