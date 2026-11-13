// Each package is the one its lock pins, with the bytes `dart pub get` checks
// out on a host with no git configuration of its own.
import 'dart:io';

import 'package:git_cyc_a/git_cyc_a.dart';
import 'package:git_cyc_b/git_cyc_b.dart';
import 'package:git_root/git_root.dart' as root;
import 'package:git_sub/git_sub.dart' as sub;
import 'package:runfiles/runfiles.dart';

final _failures = <String>[];

void _expect(String what, Object? got, Object? want) {
  // By printed form, so byte lists compare by content.
  if ('$got' != '$want') _failures.add('$what: got $got, want $want');
}

void main() {
  // The locked commit, not the branch tip, from a subdirectory...
  _expect('git_sub revision', sub.revision(), 'v1');
  // ...and from a repository's root.
  _expect('git_root revision', root.revision(), 'r1');

  // Packages that depend on each other are built together.
  _expect('git_cyc_a reaches git_cyc_b', viaB(), 'b');
  _expect('git_cyc_b reaches git_cyc_a', viaA(), 'a');

  final runfiles = Runfiles.create();
  File file(String name) =>
      File(runfiles.rlocation('rules_dart++pub+dart_pub__git_sub/lib/$name'));
  List<int>? bytes(String name) =>
      file(name).existsSync() ? file(name).readAsBytesSync() : null;
  const lf = [120, 10, 121, 10];
  const crlf = [120, 13, 10, 121, 13, 10];

  // Attributes in the repository apply, the package's and the root's.
  _expect('eol=crlf from the package', bytes('crlf.txt'), crlf);
  _expect('eol=crlf from the repository root', bytes('root_attr.txt'), crlf);
  // A file stored with CRLF and marked -text keeps it.
  _expect('-text blob', bytes('blob_crlf.txt'), crlf);
  // Anything else is as stored, whatever the client asked of git.
  _expect('plain text', bytes('plain.txt'), lf);
  // A link inside the package is kept; one out of it is not.
  _expect('link inside the package', bytes('plain_link.txt'), lf);
  _expect('link out of the package', file('escape.txt').existsSync(), false);

  if (_failures.isNotEmpty) {
    stderr.writeln(_failures.join('\n'));
    exit(1);
  }
}
