// Its part is in a directory of its own, in the package's library like every
// file under lib/.
part 'parts/twice.dart';

/// One less than [n]: a library in no cycle.
int lower(int n) => n - 1;
