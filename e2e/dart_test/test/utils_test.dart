import 'package:utils/math_utils.dart';

void main() {
  // Test factorial
  assert(factorial(0) == 1, 'factorial(0) should be 1');
  assert(factorial(1) == 1, 'factorial(1) should be 1');
  assert(factorial(5) == 120, 'factorial(5) should be 120');
  assert(factorial(10) == 3628800, 'factorial(10) should be 3628800');

  // Test isPrime
  assert(!isPrime(0), '0 is not prime');
  assert(!isPrime(1), '1 is not prime');
  assert(isPrime(2), '2 is prime');
  assert(isPrime(3), '3 is prime');
  assert(!isPrime(4), '4 is not prime');
  assert(isPrime(5), '5 is prime');
  assert(isPrime(7), '7 is prime');
  assert(!isPrime(9), '9 is not prime');

  print('All utils tests passed!');
}
