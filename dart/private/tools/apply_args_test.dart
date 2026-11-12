// How `bazel run @rules_dart//dart/format` and `@rules_dart//dart/fix` read
// their command line: `--dry-run`, then `bazel build`'s arguments as given.
import 'package:test/test.dart';

import 'apply_args.dart';

const _own = [
  '--command=format',
  '--aspect=@@rules_dart+//dart:analyze.bzl%dart_analyze',
  '--output-group=dart_format_changes',
];

ApplyArgs _parse(List<String> caller) => parseArgs([..._own, ...caller]);

Matcher _usage(String message, [String? command = 'format']) => throwsA(
  isA<UsageException>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.command, 'command', command),
);

void main() {
  test('patterns pass to the build after the flags the tool sets', () {
    final args = _parse(['//app/...', ':lib']);
    expect(args.command, 'format');
    expect(args.dryRun, isFalse);
    expect(args.buildArgs('/tmp/events.json'), [
      'build',
      '--aspects=@@rules_dart+//dart:analyze.bzl%dart_analyze',
      '--output_groups=dart_format_changes',
      '--norun_validations',
      '--build_event_json_file=/tmp/events.json',
      '//app/...',
      ':lib',
    ]);
  });

  test("the caller's flags pass in order, in any of Bazel's forms", () {
    final args = _parse([
      '--config=deep',
      '//:x',
      '--config',
      'ci',
      '-c',
      'opt',
    ]);
    expect(args.bazelArgs, [
      '--config=deep',
      '//:x',
      '--config',
      'ci',
      '-c',
      'opt',
    ]);
  });

  test('--dry-run is the tool\'s, wherever it is before `--`', () {
    final args = _parse(['--config=deep', '--dry-run', '//:x']);
    expect(args.dryRun, isTrue);
    expect(args.bazelArgs, ['--config=deep', '//:x']);
  });

  test('after `--`, everything is a pattern, as for bazel build', () {
    final args = _parse([
      '--config=deep',
      '--',
      '//app/...',
      '-//app/gen/...',
      '--dry-run',
    ]);
    expect(args.dryRun, isFalse);
    expect(args.bazelArgs, [
      '--config=deep',
      '--',
      '//app/...',
      '-//app/gen/...',
      '--dry-run',
    ]);
  });

  test('a flag the tool sets is refused, in each spelling', () {
    for (final flag in [
      '--output_groups=+default',
      '--output_groups',
      '--aspects=//x.bzl%y',
      '--build_event_json_file=/tmp/x',
      '--run_validations',
      '--norun_validations',
      '--run_validations=true',
    ]) {
      final name = flag
          .substring(2)
          .split('=')
          .first
          .replaceFirst('norun', 'run');
      expect(
        () => _parse([flag, '//:x']),
        _usage('--$name is set by this tool, so it cannot be passed'),
        reason: flag,
      );
    }
  });

  test('a flag merely sharing a prefix passes', () {
    expect(_parse(['--aspects_parameters=a=b', '//:x']).bazelArgs, [
      '--aspects_parameters=a=b',
      '//:x',
    ]);
  });

  test('after `--`, a reserved name is a pattern', () {
    expect(_parse(['--', '--output_groups']).bazelArgs, [
      '--',
      '--output_groups',
    ]);
  });

  test('naming nothing is a usage error', () {
    expect(() => _parse([]), _usage('name the targets to format'));
    expect(() => _parse(['--dry-run']), _usage('name the targets to format'));
  });

  test("the binary's own options are required", () {
    expect(
      () => parseArgs(['--command=fix', '//:x']),
      _usage('--command=, --output-group= are required', null),
    );
  });

  test('a group the targets make themselves is built without an aspect', () {
    final args = parseArgs([
      '--command=unused_deps',
      '--output-group=dart_unused_deps',
      '//app/...',
    ]);
    expect(args.aspect, isNull);
    expect(args.buildArgs('/tmp/events.json'), [
      'build',
      '--output_groups=dart_unused_deps',
      '--norun_validations',
      '--build_event_json_file=/tmp/events.json',
      '//app/...',
    ]);
  });

  test("a caller's copy of the binary's option goes to Bazel", () {
    expect(_parse(['--command=fix', '//:x']).bazelArgs, [
      '--command=fix',
      '//:x',
    ]);
  });
}
