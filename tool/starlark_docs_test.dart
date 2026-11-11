import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'starlark_docs.dart';

void main() {
  // What Bazel's `starlark_doc_extract` writes for testdata/undocumented.bzl.
  final module = ProtoMessage.decode(
    File(
      Runfiles.create().rlocation(
        '_main/tool/testdata/undocumented.binaryproto',
      ),
    ).readAsBytesSync(),
  );

  test('decodes strings and nested messages', () {
    expect(module.string(moduleFile), '//tool/testdata:undocumented.bzl');
    final [rule] = module.messages(1).toList();
    expect(rule.string(1), 'documented_rule');
    expect(rule.string(2), 'Collects Dart sources — it\'s a "library".');
    expect(rule.messages(3).map((ProtoMessage a) => a.string(1)), [
      'name',
      'srcs',
      'deps',
    ]);
  });

  test('reports every symbol and member without a doc', () {
    expect(undocumented(module), [
      'the module docstring',
      'rule `documented_rule`, attribute `deps`',
      'macro `undocumented_macro`',
      'repository rule `undocumented_repository_rule`',
      'aspect `documented_aspect`, attribute `mode`',
      'provider `DocumentedInfo`, field `deps`',
      'function `documented_function`, parameter `kwargs`',
      'module extension `documented_extension`, tag class `package`',
    ]);
  });

  test('refuses bytes that are not one message', () {
    expect(() => ProtoMessage.decode([0x0a, 0x05, 0x61]), throwsA(anything));
  });
}
