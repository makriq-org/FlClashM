# FlClashM

<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="Иконка FlClashM" width="128" height="128">
</p>

[![Загрузки](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Последний выпуск](https://img.shields.io/github/v/release/makriq-org/FlClashM?include_prereleases&style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![Лицензия](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)
[![База FlClashX](https://img.shields.io/badge/base-FlClashX-5c6bc0?style=flat-square&logo=github)](https://github.com/pluralplay/FlClashX)

FlClashM — Android-клиент для `mihomo` со встроенными узлами NaiveProxy,
ByeDPI и OlcRTC. Это форк
[FlClashX](https://github.com/pluralplay/FlClashX), ориентированный на профили,
в которых провайдер заранее описывает маршрутизацию и дополнительные способы
доставки трафика.

[English](i18n/en/README.md) · [中文](i18n/zh/README.md) ·
[فارسی](i18n/fa/README.md) · [Русская документация](i18n/ru/docs/README.md)

## Статус и границы проекта

Поддерживаемая цель выпуска — Android. В репозитории сохраняется часть
кроссплатформенной базы FlClashX, но сборки Windows, Linux, macOS и iOS не входят
в продуктовый и релизный контракт FlClashM.

Проект развивается в режиме `maintenance/cheap-upstream`: Android-путь,
безопасность, обновления и встроенные узлы поддерживаются в продуктовом слое, а
база синхронизируется с `upstream/dev` с минимальным дрейфом. Предварительные
выпуски могут менять профильный контракт; перед обновлением провайдерских
конфигураций проверяйте [CHANGELOG](CHANGELOG.md).

## Возможности

- Android VPN/TUN на встроенном `mihomo` с режимами Rule, Global и Direct.
- Профили по URL, из файла и QR-кода; обычные профили Mihomo продолжают работать
  без встроенных узлов.
- NaiveProxy, ByeDPI и OlcRTC как локальные прокси, объявленные в секции
  `proxies` YAML-профиля.
- Автоподбор стратегии ByeDPI с ограниченным foreground-бюджетом, fallback и
  проверенным кэшем.
- Спящий резервный режим OlcRTC: узел пробуждается при недоступности основной
  группы или ручном выборе. Для постоянного запуска доступен
  `activation: always`.
- Раздельное туннелирование Android-приложений из профиля: точные package name,
  маски, регулярные выражения и локальные или удалённые списки.
- Виджеты, плитка быстрых настроек, always-on восстановление и встроенная панель
  Zashboard.
- Встроенное обновление APK через подписанный каталог, проверку SHA-256 и
  проверку подписи установленного приложения средствами Android.

Встроенные узлы не являются самостоятельными VPN-протоколами FlClashM. Клиент
запускает поставляемые исполняемые файлы на loopback-адресах, проверяет их и
подменяет профильный узел на локальный SOCKS5 для `mihomo`. Серверную часть,
комнаты, ключи и учётные данные предоставляет оператор профиля.

## Скачать

Основное хранилище выпусков —
[SourceForge](https://sourceforge.net/projects/flclashm/files/releases/), зеркало
и журнал выпусков — [GitHub Releases](https://github.com/makriq-org/FlClashM/releases/).
Встроенный апдейтер использует подписанные указатели SourceForge и обращается к
GitHub как к запасному источнику или зеркалу файла при недоступности основного
канала.

| Файл | Для чего |
| --- | --- |
| `FlClashM-android-arm64-v8a.apk` | Большинство современных телефонов и планшетов |
| `FlClashM-android-armeabi-v7a.apk` | Старые 32-битные ARM-устройства |
| `FlClashM-android-x86_64.apk` | x86_64-эмуляторы и редкие x86_64-устройства |
| `FlClashM-android-universal.apk` | Универсальная запасная сборка |
| `FlClashM-android-release.aab` | Публикация через магазин; не устанавливается как APK |

Стабильный канал включён по умолчанию. Предварительные версии можно разрешить в
настройках обновления. Устанавливайте APK только из указанных выше каналов и не
обходите предупреждение Android о несовпадении подписи.

## Быстрый старт

1. Установите APK для ABI устройства или универсальную сборку.
2. Добавьте профиль по URL, из файла или QR-кода.
3. Проверьте профиль до подключения: строгая схема встроенных узлов отклоняет
   неизвестные и небезопасные поля.
4. Выберите профиль и включите VPN. Android запросит разрешение на создание
   VPN-подключения при первом запуске.

Подробности: [начало работы](i18n/ru/docs/user-guide/getting-started.md),
[встроенные узлы](i18n/ru/docs/user-guide/profiles.md),
[раздельное туннелирование](i18n/ru/docs/user-guide/split-tunneling.md) и
[подсказки провайдера](i18n/ru/docs/user-guide/provider-hints.md).

## Документация

- [Обзор документации](i18n/ru/docs/README.md)
- [Руководство пользователя](i18n/ru/docs/user-guide/README.md)
- [Архитектура](i18n/ru/docs/development/architecture.md)
- [Runtime и встроенные узлы](i18n/ru/docs/development/runtime.md)
- [Политика безопасности](i18n/ru/docs/development/security.md)
- [Релизный контракт](i18n/ru/docs/development/release-contract.md)
- [Синхронизация с FlClashX](i18n/ru/docs/development/upstream-sync.md)
- [Локальные и CI-проверки](i18n/ru/docs/development/verification.md)

## Разработка

Версии инструментов закреплены в `flake.nix` и CI: Flutter 3.41.x, JDK 17,
Go 1.26.x и Android NDK `28.0.13004108`. На NixOS достаточно:

```bash
nix develop -c make dev
```

Команда собирает arm64 debug APK в
`build/app/outputs/flutter-apk/app-debug.apk`. Полный локальный набор гейтов:

```bash
nix develop -c make check
```

Без Nix используйте те же закреплённые версии и запускайте команды из
[инструкции по проверке](i18n/ru/docs/development/verification.md). Для release
нужны закрытые ключи подписи; обычная разработка и тесты их не требуют.

## Происхождение и лицензии

FlClashM основан на [FlClashX](https://github.com/pluralplay/FlClashX) и
использует [mihomo](https://github.com/MetaCubeX/mihomo),
[ByeDPI](https://github.com/hufrea/byedpi),
[ByeByeDPI](https://github.com/romanvht/ByeByeDPI),
[OlcRTC](https://github.com/openlibrecommunity/olcrtc) и
[NaiveProxy](https://github.com/klzgrad/naiveproxy).

Код приложения распространяется по [GPL-3.0](LICENSE). Сторонние исходники и
исполняемые файлы сохраняют собственные лицензии.
