/// Finds what a public `.bzl` file leaves undocumented, from the `ModuleInfo`
/// that Bazel's `starlark_doc_extract` writes for it (`<target>.binaryproto`;
/// see stardoc_output.proto in Bazel's source).
library;

import 'dart:convert';

import 'package:protobuf/protobuf.dart';

/// A protobuf message read without its schema, by field number: the fields
/// this check reads are strings and nested messages, both length-delimited.
extension type ProtoMessage._(UnknownFieldSet _fields) {
  /// Decodes [bytes], all of which must be one message.
  factory ProtoMessage.decode(List<int> bytes) {
    final reader = CodedBufferReader(bytes);
    final fields = UnknownFieldSet()..mergeFromCodedBufferReader(reader);
    if (!reader.isAtEnd()) {
      throw const FormatException('a protobuf message ends before its bytes');
    }
    return ProtoMessage._(fields);
  }

  List<List<int>> _values(int field) =>
      _fields.getField(field)?.lengthDelimited ?? const [];

  /// Every value of the message field numbered [field].
  Iterable<ProtoMessage> messages(int field) =>
      _values(field).map(ProtoMessage.decode);

  /// The string field numbered [field], or '' when it is absent (proto3 leaves
  /// a field at its default out); its last value, as protobuf reads it.
  String string(int field) {
    final values = _values(field);
    return values.isEmpty ? '' : utf8.decode(values.last);
  }
}

// Field numbers of stardoc_output.proto, for the fields read here.

// ModuleInfo.
const _ruleInfo = 1;
const _providerInfo = 2;
const _funcInfo = 3;
const _aspectInfo = 4;
const _moduleDocstring = 5;
const _moduleExtensionInfo = 7;
const _repositoryRuleInfo = 8;
const _macroInfo = 9;

/// `ModuleInfo.file`: the label of the extracted file.
const moduleFile = 6;

// RuleInfo, MacroInfo, RepositoryRuleInfo, AspectInfo,
// ModuleExtensionInfo, ModuleExtensionTagClassInfo, ProviderInfo: the name,
// then the doc.
const _name = 1;
const _doc = 2;

// RuleInfo, MacroInfo, RepositoryRuleInfo, ModuleExtensionTagClassInfo.
const _attribute = 3;
const _aspectAttribute = 4;

// AttributeInfo, ProviderFieldInfo, FunctionParamInfo: name 1, doc 2.

// ProviderInfo.
const _fieldInfo = 3;

// StarlarkFunctionInfo.
const _functionParameter = 2;
const _functionDoc = 3;

// ModuleExtensionInfo.
const _tagClass = 3;

/// What [module] leaves undocumented, one line each: its module docstring, and
/// each public rule, macro, function, provider, aspect, repository rule and
/// module extension, with their attributes, parameters, fields and tag
/// classes.
List<String> undocumented(ProtoMessage module) {
  final gaps = <String>[];
  void need(ProtoMessage m, String what, [int doc = _doc]) {
    if (m.string(doc).trim().isEmpty) gaps.add(what);
  }

  void attributes(ProtoMessage owner, String what, [int field = _attribute]) {
    for (final a in owner.messages(field)) {
      need(a, '$what, attribute `${a.string(_name)}`');
    }
  }

  void symbols(int field, String kind, [int attribute = _attribute]) {
    for (final s in module.messages(field)) {
      final what = '$kind `${s.string(_name)}`';
      need(s, what);
      attributes(s, what, attribute);
    }
  }

  if (module.string(_moduleDocstring).trim().isEmpty) {
    gaps.add('the module docstring');
  }
  symbols(_ruleInfo, 'rule');
  symbols(_macroInfo, 'macro');
  symbols(_repositoryRuleInfo, 'repository rule');
  symbols(_aspectInfo, 'aspect', _aspectAttribute);
  for (final p in module.messages(_providerInfo)) {
    final what = 'provider `${p.string(_name)}`';
    need(p, what);
    for (final f in p.messages(_fieldInfo)) {
      need(f, '$what, field `${f.string(_name)}`');
    }
  }
  for (final f in module.messages(_funcInfo)) {
    final what = 'function `${f.string(_name)}`';
    need(f, what, _functionDoc);
    for (final p in f.messages(_functionParameter)) {
      need(p, '$what, parameter `${p.string(_name)}`');
    }
  }
  for (final e in module.messages(_moduleExtensionInfo)) {
    final what = 'module extension `${e.string(_name)}`';
    need(e, what);
    for (final t in e.messages(_tagClass)) {
      final tag = '$what, tag class `${t.string(_name)}`';
      need(t, tag);
      attributes(t, tag);
    }
  }
  return gaps;
}
