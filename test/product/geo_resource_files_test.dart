import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('engine geo file names match the bundled assets', () {
    const names = {
      GeoResource.MMDB: MMDB,
      GeoResource.ASN: ASN,
      GeoResource.GEOIP: GEOIP,
      GeoResource.GEOSITE: GEOSITE,
    };
    expect(names.values.toSet(), hasLength(GeoResource.values.length));
    for (final MapEntry(key: type, value: name) in names.entries) {
      expect(
        File('assets/data/$name').existsSync(),
        isTrue,
        reason: '$type is installed as $name on every start',
      );
    }
  });
}
