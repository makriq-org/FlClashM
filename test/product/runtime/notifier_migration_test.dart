import 'package:flclashx/common/mixin.dart';
import 'package:flclashx/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends Notifier<VpnProps>
    with AutoDisposeNotifierMixin<VpnProps> {
  final persisted = <VpnProps>[];

  @override
  VpnProps build() => const VpnProps();

  @override
  void onUpdate(VpnProps value) => persisted.add(value);
}

void main() {
  test(
    'Riverpod migration preserves persistence and identity notifications',
    () {
      final provider = NotifierProvider<_Settings, VpnProps>(_Settings.new);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifications = <VpnProps>[];
      container.listen(provider, (_, next) => notifications.add(next));
      final notifier = container.read(provider.notifier);
      final initial = container.read(provider);
      final equalCopy = initial.copyWith();
      expect(equalCopy, initial);
      expect(identical(equalCopy, initial), isFalse);

      notifier.value = equalCopy;
      expect(notifications, [equalCopy]);
      expect(notifier.persisted, [equalCopy]);

      notifier.value = equalCopy;
      expect(notifications, hasLength(1));
      expect(notifier.persisted, hasLength(1));
    },
  );
}
