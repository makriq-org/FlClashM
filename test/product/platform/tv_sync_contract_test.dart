import 'package:flclashx/product/platform/tv_sync_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tv sync contract', () {
    test('accepts canonical and legacy payload types', () {
      expect(isSupportedTvSyncPayloadType(tvSyncPayloadType), isTrue);
      expect(isSupportedTvSyncPayloadType('flclashx_tv_sync'), isTrue);
      expect(isSupportedTvSyncPayloadType('unknown'), isFalse);
      expect(isSupportedTvSyncPayloadType(null), isFalse);
    });
  });
}
