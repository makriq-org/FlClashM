<div align="center">

<img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="FlClashM" width="112" height="112">

# FlClashM

**VPN и обход блокировок на Android — в одном приложении.**

[![Release](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases) [![GPL-3.0](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)

**Русский** · [English](i18n/en/README.md) · [中文](i18n/zh/README.md) · [فارسی](i18n/fa/README.md)

</div>

Клиент mihomo на базе [FlClashX](https://github.com/pluralplay/FlClashX). Запускает ByeDPI, OlcRTC, StormDNS и NaiveProxy прямо из профиля; поддерживает подписки, раздельное туннелирование, плитку VPN и проверяемые обновления APK.

> [!NOTE]
> Проект активно развивается; некоторые функции ещё дорабатываются.

## 📥 Скачать

Скачайте APK из [GitHub Releases](https://github.com/makriq-org/FlClashM/releases). Если не знаете архитектуру устройства, выберите universal.

| Файл | Устройство |
|---|---|
| `FlClashM-android-universal.apk` | Любая поддерживаемая архитектура |
| `FlClashM-android-arm64-v8a.apk` | Большинство современных телефонов |
| `FlClashM-android-armeabi-v7a.apk` | 32-битные ARM-устройства |
| `FlClashM-android-x86_64.apk` | Эмуляторы и x86_64-устройства |
| `FlClashM-android-release.aab` | Android App Bundle |

Приложение проверяет подпись каталога и SHA-256 APK. Предварительные версии появляются в обновлениях после включения соответствующей настройки.

## 🚀 Подключиться

1. Установите APK и добавьте подписку по ссылке, из файла или QR-кода.
2. Выберите профиль и включите подключение. При первом запуске разрешите создание VPN.
3. Используйте режим правил профиля, глобальный выбор прокси или прямое соединение.

## 📚 Два руководства

| Руководство | Что внутри |
|---|---|
| [🧩 Настройка профиля](i18n/ru/docs/profiles.md) | Примеры узлов, приложения через VPN, заголовки подписки |
| [🛠 Сборка и сопровождение](i18n/ru/docs/maintenance.md) | Команды, архитектура, безопасность, диагностика и релизы |

## 💬 Сообщить о проблеме

Создайте [issue](https://github.com/makriq-org/FlClashM/issues) с версией приложения, Android/ABI, шагами и ожидаемым результатом. Диагностический ZIP экспортируется на экране логов. Не публикуйте подписки, ключи и пароли.

## 🙏 Благодарности и лицензия

Спасибо авторам [FlClashX](https://github.com/pluralplay/FlClashX), [mihomo](https://github.com/MetaCubeX/mihomo), [ByeDPI](https://github.com/hufrea/byedpi), [OlcRTC](https://github.com/openlibrecommunity/olcrtc), [StormDNS](https://github.com/nullroute1970/StormDNS), [NaiveProxy](https://github.com/klzgrad/naiveproxy).

Приложение — [GPL-3.0](LICENSE). Сторонние ядра и бинарники сохраняют собственные лицензии. История выпусков — [CHANGELOG](CHANGELOG.md).
