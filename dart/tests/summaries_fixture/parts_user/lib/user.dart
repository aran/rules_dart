import 'package:summaries_parts/parts.dart';
import 'package:summaries_parts/plain.dart';

/// Reads declarations of both parts, through the summary.
int user() => parts() + hand() + generated() + plain();
