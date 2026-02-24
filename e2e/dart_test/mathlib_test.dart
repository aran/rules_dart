import 'package:mathlib/mathlib.dart';

void main() {
  // Test factorial
  assert(factorial(0) == 1, 'factorial(0) should be 1');
  assert(factorial(1) == 1, 'factorial(1) should be 1');
  assert(factorial(5) == 120, 'factorial(5) should be 120');
  assert(factorial(10) == 3628800, 'factorial(10) should be 3628800');

  // Test negative input throws
  bool threw = false;
  try {
    factorial(-1);
  } on ArgumentError {
    threw = true;
  }
  assert(threw, 'factorial(-1) should throw ArgumentError');

  // Test isPrime
  assert(!isPrime(0), '0 is not prime');
  assert(!isPrime(1), '1 is not prime');
  assert(isPrime(2), '2 is prime');
  assert(isPrime(3), '3 is prime');
  assert(!isPrime(4), '4 is not prime');
  assert(isPrime(5), '5 is prime');
  assert(isPrime(97), '97 is prime');
  assert(!isPrime(100), '100 is not prime');

  print('All tests passed!');
}
