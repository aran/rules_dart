import 'package:legacy_mixin_fixture_legacy/legacy.dart';

class MidMixin {
  String prefix = 'mid';

  String decorate(String s) => '$prefix[$s]';
}

class ChainedLegacy = Object with LegacyMixin, MidMixin;
