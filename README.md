<div align="center">

<img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="FlClashM" width="128" height="128">

# FlClashM

**Обход блокировок в Android — за одной кнопкой.**

[![Загрузки](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Последняя версия](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![Лицензия](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)
[![На базе FlClashX](https://img.shields.io/badge/based%20on-FlClashX-5c6bc0?style=flat-square&logo=github)](https://github.com/pluralplay/FlClashX)

Android-клиент для `mihomo`, форк [FlClashX](https://github.com/pluralplay/FlClashX), который прячет сложные инструменты обхода блокировок за одним переключателем.

**Русский** · [English](i18n/en/README.md) · [中文](i18n/zh/README.md) · [فارسی](i18n/fa/README.md)

</div>

---

> [!WARNING]
> Проект в активной разработке. Некоторые функции ещё дорабатываются, а интерфейс может меняться.

## 📑 Оглавление

- [Зачем этот клиент](#-зачем-этот-клиент)
- [Главные преимущества](#-главные-преимущества)
- [Что ещё умеет](#-что-ещё-умеет)
- [Скачать](#-скачать)
- [Документация](#-документация)
- [Сборка](#-сборка)
- [Благодарности](#-благодарности)
- [Лицензия](#-лицензия)

---

## 🎯 Зачем этот клиент

Есть несколько мощных инструментов обхода блокировок, и каждый живёт в своём «загоне»:

- 🛡 **[ByeDPI](https://github.com/hufrea/byedpi)** — обход DPI для доступа к ресурсам, заблокированным «изнутри» (например, YouTube или Discord для РФ).
- 📞 **[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — обход белых списков маскировкой под WebRTC-звонки разрешённых сервисов, таких как Yandex Telemost.
- 🌩 **[StormDNS](https://github.com/nullroute1970/StormDNS)** — обход белых списков маскировкой под обычные DNS-запросы к разрешённому резольверу.
- 🎭 **[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — обход чёрных списков маскировкой под трафик браузера Chrome.

Каждая технология хороша для своей задачи, но не было места, которое объединяло бы их все. Хотелось задать всё в одном месте и просто нажать «подключиться».

Поэтому появился **FlClashM**. Его задача — стать той самой **одной кнопкой**: провайдер готовит конфигурацию, пользователь нажимает переключатель, и соединение работает в любой сети.

---

## ✨ Главные преимущества

### 🧩 Встроенные узлы прямо в профиле

В отличие от обычных клиентов, FlClashM умеет запускать **специальные узлы прямо из YAML-профиля**. Они выглядят как обычные прокси и участвуют в правилах маршрутизации: один сайт можно направить через ByeDPI, другой — через OlcRTC, а всё остальное — напрямую.

<table>
<tr><td>

🛡 **ByeDPI** — автоперебор стратегий обхода DPI с кэшированием рабочей.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    strategies:
      - builtin:byebyeedpi
      - "--disorder 1"
```

</td></tr>
<tr><td>

📞 **OlcRTC** — туннель поверх WebRTC под видом видеозвонка.

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    provider: jitsi
    room: "https://meet.example.org/room"
    encryption-key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    transport: datachannel
    dns-server: "1.1.1.1:53"
```

</td></tr>
<tr><td>

🌩 **StormDNS** — туннель внутри обычных DNS-запросов.

```yaml
proxies:
  - name: "storm"
    type: stormdns
    domains: ["v.example.com"]
    encryption: chacha20
    encryption-key: "<key>"
```

</td></tr>
<tr><td>

🎭 **NaiveProxy** — маскировка под трафик Chrome.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

</td></tr>
</table>

📖 [Подробнее о встроенных узлах →](i18n/ru/docs/user-guide/profiles.md)

### 🎯 Раздельное туннелирование через профиль

Провайдер может задать правила раздельного туннелирования прямо в профиле — какие приложения идут через VPN, а какие нет. Поддерживаются точные имена пакетов, маски и регулярные выражения; списки можно загружать из файлов или URL. Профиль имеет приоритет над ручными настройками.

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
  exclude-package:
    - '*.yandex.*'
    - '!ru.yandex.browser'
```

📖 [Подробнее о раздельном туннелировании →](i18n/ru/docs/user-guide/split-tunneling.md)

---

## 🛠 Что ещё умеет

- 🔌 **VPN/TUN-подключение** через `mihomo`.
- 📥 **Профили** по ссылке, из файла, по QR-коду и с Android TV.
- 🔀 **Режимы работы**: правила, глобальный, прямое соединение.
- 🧰 **Виджеты** и **плитка быстрых настроек** для управления VPN.
- ⬆️ **Встроенное обновление** с проверкой подписи и контрольных сумм.
- 🔔 **Уведомления** об истечении подписки.
- 🚀 **Автозапуск** после перезагрузки устройства.
- 🎨 **Оформление** через [подсказки провайдера](i18n/ru/docs/user-guide/provider-hints.md).

---

## 📥 Скачать

Готовые сборки публикуются в [GitHub Releases](https://github.com/makriq-org/FlClashM/releases).

| Файл | Для чего |
|------|----------|
| `FlClashM-android-universal.apk` | Универсальная сборка (подойдёт, если сомневаетесь) |
| `FlClashM-android-arm64-v8a.apk` | 64-битные ARM (большинство современных телефонов) |
| `FlClashM-android-armeabi-v7a.apk` | 32-битные ARM (старые устройства) |
| `FlClashM-android-x86_64.apk` | x86_64 (эмуляторы, отдельные планшеты) |
| `FlClashM-android-release.aab` | Android App Bundle |

> [!NOTE]
> По умолчанию встроенный загрузчик показывает только стабильные версии. Предварительные сборки можно включить в настройках.

---

## 📚 Документация

Полный справочник — в **[центре документации](i18n/ru/docs/README.md)**.

**🚀 Для пользователей**
- 🧩 [Встроенные узлы](i18n/ru/docs/user-guide/profiles.md) — ByeDPI, OlcRTC, StormDNS, NaiveProxy
- 🎯 [Раздельное туннелирование](i18n/ru/docs/user-guide/split-tunneling.md) — управление через профиль
- 🎨 [Подсказки провайдера](i18n/ru/docs/user-guide/provider-hints.md) — оформление и поведение

**🛠 Для разработчиков**
- 🏗 [Архитектура](i18n/ru/docs/development/architecture.md) · ⚙️ [Среда выполнения](i18n/ru/docs/development/runtime.md) · 🔒 [Безопасность](i18n/ru/docs/development/security.md)
- 📦 [Релизы](i18n/ru/docs/development/release-contract.md) · 🔄 [Синхронизация с FlClashX](i18n/ru/docs/development/upstream-sync.md) · ✅ [Проверка сборки](i18n/ru/docs/development/verification.md)

---

## 🏗 Сборка

Нужны **Flutter 3.41.x**, **JDK 17**, **Android SDK/NDK** и **Go 1.26.x**.

### На NixOS (рекомендуется)

Все зависимости и их версии задаёт `flake.nix`. Отладочный пакет для arm64 собирается одной командой:

```bash
nix develop -c make dev
```

Результат: `build/app/outputs/flutter-apk/app-debug.apk`.

Остальные задачи запускаются так же:

```bash
nix develop -c make fetch-upstream check
nix develop -c make install-dev
nix develop -c make release
nix develop -c make clean
```

> Отдельно доступны цели `test`, `analyze`, `boundaries`, `release-contract` и `drift`.

### Без Nix

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

📖 Подробнее — в [проверке сборки](i18n/ru/docs/development/verification.md).

---

## 🙏 Благодарности

FlClashM построен на базе [FlClashX](https://github.com/pluralplay/FlClashX) — отличного кроссплатформенного клиента для Clash/Mihomo. Огромное спасибо авторам за проделанную работу и открытый код, без которого этот проект был бы невозможен.

Отдельная благодарность авторам [ByeDPI](https://github.com/hufrea/byedpi), [OlcRTC](https://github.com/openlibrecommunity/olcrtc), [StormDNS](https://github.com/nullroute1970/StormDNS) и [NaiveProxy](https://github.com/klzgrad/naiveproxy) — без их труда обход блокировок был бы невозможен.

---

## 📄 Лицензия

Код приложения распространяется по лицензии **GPL-3.0**. Сторонние ядра и встроенные исполняемые файлы сохраняют свои исходные лицензии.
