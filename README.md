# FlClashM

[English](README_EN.md)

[![Downloads](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Last Version](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![License](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)

`FlClashM` — Android-клиент для `mihomo` на базе `FlClashX`.

Проект сохраняет установочный пакет `com.makriq.flclash` и канал релизов
`makriq-org/FlClashM`, чтобы обновления продолжали приходить пользователям
старой Android-ветки `FlClash-my`.

## Возможности

- VPN/TUN-подключение через `mihomo`.
- Профили из ссылки, файла, QR-кода и передачи на Android TV.
- Режимы `rule`, `global`, `direct`, проверка задержек и выбор узлов в группах.
- Встроенные локальные узлы `naiveproxy`, `olcrtc` и `byedpi`.
- Виджеты главной страницы: профиль, трафик, IP, режим, смена узла, сведения сервиса.
- Настройки внешнего вида и поведения через безопасные подсказки `flclashm-*`.
- Загрузчик обновлений с обычными и предварительными релизами, отказом от найденной
  версии и показом хода скачивания.
- Постоянное уведомление и плитка быстрых настроек Android.

## Отличия от базы

- Поддерживается только Android. Код других платформ остается в дереве как часть
  унаследованной базы, но не является целью релизов.
- Продуктовая логика вынесена в `lib/product/**`: компиляция профиля, политика
  безопасности, запуск ядра, обновления и Android-мосты.
- Критичные для безопасности решения принимает клиент. Подписка может передавать только
  сведения и подсказки, но не может ослабить базовую Android-политику.
- `naiveproxy`, `olcrtc` и `byedpi` подключены как обычные узлы профиля через
  локальные SOCKS5-слушатели.
- Ссылка на используемое ядро: [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo).
- База проекта: [pluralplay/FlClashX](https://github.com/pluralplay/FlClashX).

## Скачать

Готовые сборки публикуются в
[GitHub Releases](https://github.com/makriq-org/FlClashM/releases).

Артефакты Android:

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

По умолчанию встроенный загрузчик показывает только стабильные релизы.
Предварительные сборки включаются отдельно в настройках.

## Сборка

Нужны Flutter 3.41.x, JDK 17, Android SDK/NDK и Go 1.26.x.
На NixOS удобнее запускать команды из чистой оболочки с этими пакетами.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

Проверка релизного пути описана в [docs/base-verification.md](docs/base-verification.md).
Подписанные публичные релизы собираются через GitHub Actions и требуют секреты
`KEYSTORE`, `KEY_ALIAS`, `STORE_PASSWORD`, `KEY_PASSWORD`.

## Настройки провайдера

Подписка может передавать заголовки `flclashm-*` для оформления и удобства:

- `flclashm-widgets` — порядок виджетов главной страницы.
- `flclashm-view` — вид страницы узлов.
- `flclashm-custom` — когда применять оформление: при добавлении или обновлении.
- `flclashm-denywidgets` — запрет ручного изменения главной страницы.
- `flclashm-servicename`, `flclashm-servicelogo`, `flclashm-serverinfo` — сведения сервиса.
- `flclashm-background`, `flclashm-hex` — оформление.
- `flclashm-settings` — подсказки для автозапуска и проверки обновлений.
- `flclashm-globalmode` — видимость выбора режима.

Полный контракт: [docs/product-customization.md](docs/product-customization.md).
Политика безопасности: [docs/security-policy.md](docs/security-policy.md).

## Документация

- [Архитектура](docs/architecture.md)
- [Среда выполнения и встроенные узлы](docs/runtime.md)
- [ByeDPI](docs/byedpi.md)
- [Политика безопасности](docs/security-policy.md)
- [План миграции](docs/migration-plan.md)
- [Контракт релизов](docs/release-contract.md)
- [Границы совместимости](docs/compatibility-boundaries.md)

## Лицензия

Код распространяется по лицензии GPL-3.0. Сторонние ядра и встроенные
исполняемые файлы сохраняют свои исходные лицензии; сведения о них находятся в
`assets/runtimes/**/README.md` и профильных документах `docs/**`.
