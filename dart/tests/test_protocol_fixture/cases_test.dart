import 'package:test/test.dart';

/// Cases the protocol tests select, split and time. `filtered_out` fails, so a
/// filter that lets it through is caught; `explicit timeout` fails, because
/// its own timeout must still apply.
void main() {
  test('alpha', () {});
  test('beta', () {});
  test('gamma', () {});
  test('filtered_out', () {
    fail('the --test_filter did not exclude this case');
  }, tags: ['filtered_out']);

  // Skipped, so it never runs: unless a developer's own `run_skipped: true`
  // config leaks into the run.
  test('never runs', () {
    fail('a per-user package:test config was read');
  }, skip: 'runs only if a per-user config is read');

  // A timeout a test states itself still applies: this fails when it runs.
  test(
    'explicit timeout',
    () => Future<void>.delayed(const Duration(seconds: 2)),
    timeout: const Timeout(Duration(milliseconds: 200)),
  );

  // `package:test` defaults each case to 30 s. Scaled by 0.05 that is 1.5 s,
  // which this case outlives; it passes only when the default is Bazel's
  // timeout (60 s for a small test, so 3 s) rather than `package:test`'s.
  test(
    'no package:test default timeout',
    () => Future<void>.delayed(const Duration(seconds: 2)),
    timeout: const Timeout.factor(0.05),
  );
}
