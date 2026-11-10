import 'dart:convert';

// A program with real work in it, so that a compiled output has something in
// it to vary: a trivial `main` would compile the same anywhere.
void main() {
  var total = 0;
  final pattern = RegExp(r'(\d+)-(\w+)');
  for (var i = 0; i < 20000; i++) {
    final decoded = jsonDecode(
      jsonEncode({
        'n': i,
        'k': 'v$i',
        'l': [i, i + 1],
      }),
    );
    final match = pattern.firstMatch('${decoded['n']}-${decoded['k']}');
    total += match!.group(1)!.length + (decoded['l'] as List).length;
  }
  // No `dart:io`: the compiled outputs are compared byte for byte.
  // ignore: avoid_print
  print(total);
}
