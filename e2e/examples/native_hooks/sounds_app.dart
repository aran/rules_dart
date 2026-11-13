import 'dart:io';

import 'package:banner/banner.dart';
import 'package:sounds/sounds.dart';

void main() {
  stdout
    ..writeln(bannerAssetId)
    ..writeln(const Sound('chime').assetId);
}
