import 'dart:convert';
import 'dart:io';

import 'package:kernel_list/kernel_list.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The argument is the runfiles path of `kernel_list_fixture`'s launcher; its
/// program is the kernel list in the launcher's configuration beside it.
void main(List<String> args) {
  final runfiles = Runfiles.create();
  final launcher = runfiles.rlocation(args.single);
  final config = jsonDecode(
    File('${launcher.replaceFirst(RegExp(r'\.exe$'), '')}.launcher.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final program = config['dill'] as String;
  const expected = 'kernel_list_fixture ran with Runfiles';
  // With `--@rules_dart//dart:kernel_list=false` the fixture's program is one
  // joined kernel, and only what holds for one kernel is tested.
  final severalKernels = config['kernel_list'] == true
      ? false
      : 'kernel lists are off';

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kernel_list_test.'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProcessResult> run(String program) =>
      Process.run(Platform.resolvedExecutable, ['--enable-asserts', program]);

  test("a modular test's program is a kernel list, its entry first", () {
    expect(isKernelList(runfiles.rlocation(program)), isTrue);
    final kernels = kernelsInRunfiles(runfiles, program);
    expect(kernels.first, endsWith('kernel_list_fixture.entry.dill'));
    // The entry, the test's own module and its dependency's.
    expect(kernels.length, greaterThanOrEqualTo(3));
    for (final kernel in kernels) {
      expect(File(kernel).existsSync(), isTrue, reason: kernel);
      expect(isKernelList(kernel), isFalse, reason: kernel);
    }
  }, skip: severalKernels);

  test('a list naming the kernels where they are runs from anywhere', () async {
    final list = '${tmp.path}/program.dill';
    writeKernelList(list, kernelsInRunfiles(runfiles, program));
    final result = await run(list);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect('${result.stdout}'.trim(), expected);
  });

  test(
    'kernelsAt resolves relative lines against the list as the VM does',
    () async {
      final kernels = kernelsInRunfiles(runfiles, program);
      final sep = Platform.pathSeparator;
      final sub = Directory('${tmp.path}${sep}sub')..createSync();
      File(kernels.first).copySync('${sub.path}${sep}entry.dill');
      final list = '${sub.path}${sep}program.dill';
      writeKernelList(list, ['entry.dill', ...kernels.skip(1)]);
      expect(kernelsAt(list), [
        '${sub.path}${sep}entry.dill',
        ...kernels.skip(1),
      ]);
      final result = await run(list);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect('${result.stdout}'.trim(), expected);
      expect(kernelsAt(kernels[1]), [kernels[1]]);
    },
    skip: severalKernels,
  );

  test('joinKernels makes one program of them, in order', () async {
    final kernels = kernelsInRunfiles(runfiles, program);
    final joined = joinKernels(kernels, temporaryDirectory: tmp.path);
    addTearDown(joined.close);
    if (Platform.isLinux) {
      expect(joined.path, startsWith('/proc/$pid/fd/'));
    }
    expect(File(joined.path).readAsBytesSync(), [
      for (final kernel in kernels) ...File(kernel).readAsBytesSync(),
    ]);
    // The VM takes Linux's descriptor path only as a URI.
    final result = await run(Platform.isLinux ? joined.uri : joined.path);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect('${result.stdout}'.trim(), expected);
  }, skip: severalKernels);

  test('closing a joined program releases it', () {
    final joined = joinKernels(
      kernelsInRunfiles(runfiles, program),
      temporaryDirectory: tmp.path,
    );
    expect(File(joined.path).existsSync(), isTrue);
    joined.close();
    expect(File(joined.path).existsSync(), isFalse);
    expect(tmp.listSync(), isEmpty);
  }, skip: severalKernels);

  test('a kernel the list names but runfiles lack fails, naming the flag', () {
    final list = '${tmp.path}/program.dill';
    writeKernelList(list, ['program.entry.dill', '../dep/missing.dill']);
    final manifest = Runfiles.fromState(
      manifest: {
        '_main/pkg/program.dill': list,
        '_main/pkg/program.entry.dill': list,
      },
    );
    expect(
      () => kernelsInRunfiles(manifest, '_main/pkg/program.dill'),
      throwsA(
        isA<KernelListException>().having(
          (e) => '$e',
          'message',
          allOf(
            contains('names ../dep/missing.dill'),
            contains('--@rules_dart//dart:kernel_list=false'),
          ),
        ),
      ),
    );
  });

  test('one kernel is not copied', () {
    final kernel = kernelsInRunfiles(runfiles, program).first;
    final joined = joinKernels([kernel], temporaryDirectory: tmp.path);
    expect(joined.path, kernel);
    joined.close();
    expect(File(kernel).existsSync(), isTrue);
  });
}
