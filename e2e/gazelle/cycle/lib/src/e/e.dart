// Its part is in a directory of its own, which Gazelle makes part of this
// directory's library.
part 'parts/twice.dart';

/// One less than [n]: a library in no cycle.
int lower(int n) => n - 1;
