import '../d/d.dart';

/// Counts down from [n] with `d`.
List<int> countdown(int n) => n < 0 ? [] : [n, ...down(n)];
