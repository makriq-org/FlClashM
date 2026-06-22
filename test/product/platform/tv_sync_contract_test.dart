import 'package:flclashx/product/platform/tv_sync_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tv sync contract', () {
    test('accepts canonical payload type only', () {
      expect(isSupportedTvSyncPayloadType(tvSyncPayloadType), isTrue);
      expect(isSupportedTvSyncPayloadType('unknown'), isFalse);
      expect(isSupportedTvSyncPayloadType(null), isFalse);
    });
  });
}
