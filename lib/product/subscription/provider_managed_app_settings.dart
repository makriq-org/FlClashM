import 'package:flclashx/providers/config.dart';
import 'package:flclashx/providers/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Настройки приложения, которые способен переписать провайдер подписки.
///
/// Список должен совпадать с полями, которые действительно проставляет
/// `ProductProviderCustomization.buildPatch` в `provider_advisory.dart`.
/// Всё, чего здесь нет, провайдер не трогает — и запирать это в интерфейсе
/// незачем.
enum ProductManagedAppSetting {
  minimizeOnExit,
  autoLaunch,
  silentLaunch,
  autoRun,
  autoCheckUpdate,
}

/// Есть ли у текущего профиля провайдерские настройки приложения.
///
/// Без подписки блокировать нечего: на свежей установке пункты должны быть
/// обычными, а не серыми.
final productProviderManagesAppSettingsProvider = Provider.autoDispose<bool>(
  (ref) =>
      ref
          .watch(currentProductAdvisoryProvider)
          .customization
          .subscriptionSettings !=
      null,
);

/// Заблокирован ли пункт настроек прямо сейчас.
///
/// Замок навешивается, только когда провайдер этой настройкой действительно
/// управляет и пользователь не включил переопределение.
final productAppSettingLockedProvider =
    Provider.autoDispose.family<bool, ProductManagedAppSetting>((ref, setting) {
  if (!ref.watch(productProviderManagesAppSettingsProvider)) {
    return false;
  }
  final overrideProviderSettings = ref.watch(
    appSettingProvider.select((state) => state.overrideProviderSettings),
  );
  return !overrideProviderSettings;
});
