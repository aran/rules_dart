// Makes the `deps` removals buildozer made in a formatted copy of a BUILD file
// in the file as it was written, changing nothing else.
//
// buildozer formats every file it edits, so what it writes also holds whatever
// buildifier would change. Comparing its output with the formatted copy it
// started from says which strings left each call's `deps`; those are then cut
// from the original text. The caller checks the result by formatting it: it
// must then say what buildozer wrote (`sameBuild`).

/// [original] with the strings that left a call's `deps` between [formatted]
/// (it, formatted) and [edited] removed, or null when one cannot be found.
String? applyRemovals({
  required String original,
  required String formatted,
  required String edited,
}) {
  final before = _calls(formatted);
  final after = _calls(edited);
  final calls = _calls(original);
  final cuts = <_Span>[];
  for (final MapEntry(key: name, value: call) in before.entries) {
    final left = [
      for (final s in after[name]?.strings ?? const <_Str>[]) _label(s.value),
    ];
    final removed = [
      for (final s in call.strings)
        if (!left.remove(_label(s.value))) _label(s.value),
    ];
    if (removed.isEmpty) continue;
    final target = calls[name];
    if (target == null) return null;
    final remaining = [...target.strings];
    final taken = <_Str>[];
    for (final value in removed) {
      final index = remaining.indexWhere((s) => _label(s.value) == value);
      if (index < 0) return null;
      taken.add(remaining.removeAt(index));
    }
    if (remaining.isEmpty && target.isOneList) {
      cuts.add(_wholeLines(original, target.attribute));
    } else {
      cuts.addAll(taken.map((s) => _element(original, s)));
    }
  }
  return _cut(original, cuts);
}

/// Whether two formatted BUILD files say the same, whatever their layout: a
/// list buildozer shortens to one line stays on several when only formatted.
bool sameBuild(String a, String b) {
  List<String> said(String text) {
    final tokens = _tokens(text);
    return [
      for (final (i, token) in tokens.indexed)
        if (!token.isMark(',') ||
            i + 1 == tokens.length ||
            !_isCloser(tokens[i + 1]))
          '${token.kind.name} ${token.text}',
    ];
  }

  final (first, second) = (said(a), said(b));
  if (first.length != second.length) return false;
  for (final (i, word) in first.indexed) {
    if (word != second[i]) return false;
  }
  return true;
}

bool _isCloser(_Token token) =>
    token.kind == _Kind.punctuation && _close.contains(token.text);

/// The target [written] names, the same for every spelling of it: buildifier
/// writes `//a/b:b` as `//a/b` and `@a//:a` as `@a`, and leaves other forms.
/// `@` and `@@` stay apart, as an apparent and a canonical name are not one.
String _label(String written) {
  final slashes = written.indexOf('//');
  if (slashes < 0 && !written.startsWith('@')) {
    return written.startsWith(':') ? written : ':$written';
  }
  final repo = slashes < 0 ? written : written.substring(0, slashes);
  final path = slashes < 0 ? '' : written.substring(slashes + 2);
  final colon = path.indexOf(':');
  if (colon >= 0) return '$repo//$path';
  final last = path.substring(path.lastIndexOf('/') + 1);
  final name = last.isEmpty ? repo.replaceFirst(RegExp('^@+'), '') : last;
  return '$repo//$path:$name';
}

class _Span {
  _Span(this.start, this.end);
  final int start;
  final int end;
}

/// A string of a `deps` value, with the commas around it, where there are any.
class _Str {
  _Str(this.value, this.span, this.commaBefore, this.commaAfter);
  final String value;
  final _Span span;
  final _Span? commaBefore;
  final _Span? commaAfter;
}

/// What a call's `deps` holds.
class _Call {
  _Call(this.strings, this.attribute, this.isOneList);
  final List<_Str> strings;

  /// From `deps` through the comma after its value.
  final _Span attribute;

  /// Whether the value is one list and nothing else.
  final bool isOneList;
}

String _cut(String text, List<_Span> cuts) {
  final sorted = [...cuts]..sort((a, b) => a.start.compareTo(b.start));
  final out = StringBuffer();
  var at = 0;
  for (final cut in sorted) {
    if (cut.start > at) out.write(text.substring(at, cut.start));
    if (cut.end > at) at = cut.end;
  }
  out.write(text.substring(at));
  return out.toString();
}

/// What removing [s] from its list takes out of [text].
_Span _element(String text, _Str s) {
  final end = s.commaAfter?.end ?? s.span.end;
  final own = _wholeLines(text, _Span(s.span.start, end));
  if (own.start != s.span.start || own.end != end) {
    // Alone on its lines. The comment lines above it belong to it, as they do
    // for buildifier.
    var start = own.start;
    while (start > 1) {
      final above = text.lastIndexOf('\n', start - 2) + 1;
      if (!text.substring(above, start).trimLeft().startsWith('#')) break;
      start = above;
    }
    return _Span(start, own.end);
  }
  if (s.commaAfter case final comma?) {
    var stop = comma.end;
    while (stop < text.length && text[stop] == ' ') {
      stop++;
    }
    return _Span(s.span.start, stop);
  }
  return _Span(s.commaBefore?.start ?? s.span.start, s.span.end);
}

/// [span] widened to whole lines, when only blanks or a comment share them.
_Span _wholeLines(String text, _Span span) {
  final start = text.lastIndexOf('\n', span.start - 1) + 1;
  if (text.substring(start, span.start).trim().isNotEmpty) return span;
  var end = text.indexOf('\n', span.end);
  end = end < 0 ? text.length : end + 1;
  final rest = text.substring(span.end, end).trim();
  if (rest.isNotEmpty && !rest.startsWith('#')) return span;
  return _Span(start, end);
}

enum _Kind { name, string, punctuation }

class _Token {
  _Token(this.kind, this.text, this.start, this.end);
  final _Kind kind;

  /// A name, a punctuation mark, or what a string holds between its quotes.
  final String text;
  final int start;
  final int end;

  bool isMark(String mark) => kind == _Kind.punctuation && text == mark;
  _Span get span => _Span(start, end);
}

final _nameStart = RegExp(r'[A-Za-z_]');
final _namePart = RegExp(r'\w');

List<_Token> _tokens(String text) {
  final tokens = <_Token>[];
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == '#') {
      final end = text.indexOf('\n', i);
      i = end < 0 ? text.length : end;
    } else if (c.trim().isEmpty) {
      i++;
    } else if (c == '"' || c == "'") {
      final quote = text.startsWith(c * 3, i) ? c * 3 : c;
      var end = i + quote.length;
      while (end < text.length && !text.startsWith(quote, end)) {
        end += text[end] == r'\' ? 2 : 1;
      }
      final value = text.substring(i + quote.length, end.clamp(0, text.length));
      end = (end + quote.length).clamp(0, text.length);
      tokens.add(_Token(_Kind.string, value, i, end));
      i = end;
    } else if (_nameStart.hasMatch(c)) {
      var end = i + 1;
      while (end < text.length && _namePart.hasMatch(text[end])) {
        end++;
      }
      tokens.add(_Token(_Kind.name, text.substring(i, end), i, end));
      i = end;
    } else {
      tokens.add(_Token(_Kind.punctuation, c, i, i + 1));
      i++;
    }
  }
  return tokens;
}

const _open = {'(', '[', '{'};
const _close = {')', ']', '}'};

/// The top-level calls of [text] that have a literal `name` and a `deps`, by
/// name.
Map<String, _Call> _calls(String text) {
  final tokens = _tokens(text);
  final calls = <String, _Call>{};
  var depth = 0;
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.kind == _Kind.punctuation) {
      if (_open.contains(token.text)) depth++;
      if (_close.contains(token.text)) depth--;
    }
    if (depth != 1 || !token.isMark('(') || i == 0) continue;
    if (tokens[i - 1].kind != _Kind.name) continue;
    final (:name, :call, :end) = _readCall(tokens, i);
    if (name != null && call != null) calls[name] = call;
    i = end;
    depth = 0;
  }
  return calls;
}

/// Reads the call whose `(` is `tokens[open]`, answering the token closing it.
({String? name, _Call? call, int end}) _readCall(
  List<_Token> tokens,
  int open,
) {
  String? name;
  _Call? call;
  var depth = 1;
  var i = open + 1;
  while (i < tokens.length && depth > 0) {
    final token = tokens[i];
    final isAttribute =
        depth == 1 &&
        token.kind == _Kind.name &&
        i + 2 < tokens.length &&
        tokens[i + 1].isMark('=');
    if (isAttribute && token.text == 'name') {
      if (tokens[i + 2].kind == _Kind.string) name = tokens[i + 2].text;
    } else if (isAttribute && token.text == 'deps') {
      final (:value, :end) = _readValue(tokens, i);
      call = value;
      i = end;
      continue;
    }
    if (token.kind == _Kind.punctuation) {
      if (_open.contains(token.text)) depth++;
      if (_close.contains(token.text)) depth--;
    }
    i++;
  }
  return (name: name, call: call, end: i - 1);
}

/// Reads the `deps` attribute at `tokens[start]`, answering the index after it.
({_Call value, int end}) _readValue(List<_Token> tokens, int start) {
  final strings = <_Str>[];
  final first = start + 2;
  var depth = 0;
  var i = first;
  while (i < tokens.length) {
    final token = tokens[i];
    if (token.kind == _Kind.punctuation) {
      if (depth == 0 && (token.text == ',' || token.text == ')')) break;
      if (_open.contains(token.text)) depth++;
      if (_close.contains(token.text)) depth--;
    } else if (token.kind == _Kind.string) {
      final next = i + 1 < tokens.length ? tokens[i + 1] : null;
      // The key of a `select()` branch is a condition, not a dep.
      if (next == null || !next.isMark(':')) {
        final previous = tokens[i - 1];
        strings.add(
          _Str(
            token.text,
            token.span,
            previous.isMark(',') ? previous.span : null,
            next != null && next.isMark(',') ? next.span : null,
          ),
        );
      }
    }
    i++;
  }
  final isOneList =
      i - 1 > first &&
      tokens[first].isMark('[') &&
      tokens[i - 1].isMark(']') &&
      _closes(tokens, first, i - 1);
  final hasComma = i < tokens.length && tokens[i].isMark(',');
  final last = hasComma ? tokens[i] : tokens[i - 1];
  return (
    value: _Call(strings, _Span(tokens[start].start, last.end), isOneList),
    end: hasComma ? i + 1 : i,
  );
}

/// Whether the bracket at [open] is closed by the one at [close].
bool _closes(List<_Token> tokens, int open, int close) {
  var depth = 0;
  for (var i = open; i <= close; i++) {
    final token = tokens[i];
    if (token.kind != _Kind.punctuation) continue;
    if (_open.contains(token.text)) depth++;
    if (_close.contains(token.text)) depth--;
    if (depth == 0) return i == close;
  }
  return false;
}
