import 'package:test/test.dart';

// Import the library directly — it uses only dart:* packages.
import '../codegen_worker.dart';

void main() {
  group('parseArgs', () {
    test('extracts --generator and passes remaining args', () {
      final result = parseArgs([
        '--generator', '/path/to/gen.dart',
        '--input', 'foo.dart',
        '--output', 'foo.g.dart',
      ]);
      expect(result.generator, '/path/to/gen.dart');
      expect(result.generatorArgs, ['--input', 'foo.dart', '--output', 'foo.g.dart']);
    });

    test('throws ArgumentError on missing --generator', () {
      expect(
        () => parseArgs(['--input', 'foo.dart']),
        throwsArgumentError,
      );
    });

    test('handles --generator as last pair of args', () {
      final result = parseArgs([
        '--input', 'foo.dart',
        '--generator', '/gen.dart',
      ]);
      expect(result.generator, '/gen.dart');
      expect(result.generatorArgs, ['--input', 'foo.dart']);
    });
  });

  group('WorkRequest.fromJson', () {
    test('parses arguments list and requestId', () {
      final req = WorkRequest.fromJson({
        'arguments': ['--generator', 'gen.dart', '--input', 'a.dart'],
        'requestId': 42,
      });
      expect(req.arguments, ['--generator', 'gen.dart', '--input', 'a.dart']);
      expect(req.requestId, 42);
    });

    test('defaults requestId to 0', () {
      final req = WorkRequest.fromJson({
        'arguments': ['--generator', 'gen.dart'],
      });
      expect(req.requestId, 0);
    });
  });

  group('WorkResponse.toJson', () {
    test('round-trips correctly', () {
      final response = WorkResponse(
        exitCode: 0,
        output: 'success',
        requestId: 7,
      );
      final json = response.toJson();
      expect(json['exitCode'], 0);
      expect(json['output'], 'success');
      expect(json['requestId'], 7);
    });
  });
}
