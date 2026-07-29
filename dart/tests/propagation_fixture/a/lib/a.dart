import 'package:prop_b/b.dart';

/// Depends on `prop_b` but declares no assets of its own — the middle of the
/// diamond.
String aName() => 'prop_a:${bName()}';
