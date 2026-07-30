import 'package:flclashx/models/models.dart';
import 'package:flclashx/product/compile/product_compile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FlClashM GLOBAL override takes priority over the upstream field', () {
    expect(
      resolveGlobalGroupOverride(const {
        'flclashx-override': true,
        'flclashm-override': false,
      }),
      isFalse,
    );
    expect(
      resolveGlobalGroupOverride(const {'flclashx-override': true}),
      isTrue,
    );
  });

  test('both provider prefixes can request Android secure mode', () {
    expect(
      profileRequestsAndroidSecure(
        const Profile(
          id: 'upstream',
          autoUpdateDuration: Duration.zero,
          providerHeaders: {'flclashx-androidsecure': 'true'},
        ),
      ),
      isTrue,
    );
    expect(
      profileRequestsAndroidSecure(
        const Profile(
          id: 'flclashm',
          autoUpdateDuration: Duration.zero,
          providerHeaders: {'flclashm-androidsecure': 'true'},
        ),
      ),
      isTrue,
    );
    expect(
      profileRequestsAndroidSecure(
        const Profile(
          id: 'priority',
          autoUpdateDuration: Duration.zero,
          providerHeaders: {
            'flclashx-androidsecure': 'true',
            'flclashm-androidsecure': 'false',
          },
        ),
      ),
      isFalse,
    );
  });
}
