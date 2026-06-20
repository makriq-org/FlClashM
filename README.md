# FlClashM

[![Загрузки](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Последняя версия](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![Лицензия](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)

> Android-клиент для `mihomo`, который прячет сложные инструменты обхода блокировок за одной кнопкой.

[English version](README_EN.md) | [中文版](README_ZH.md)

---

## Зачем этот клиент

Существует несколько мощных инструментов для обхода блокировок:

- **[ByeDPI](https://github.com/hufrea/byedpi)** — обход DPI для доступа к ресурсам, заблокированным "изнутри" (например, YouTube или Discord для РФ).
- **[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — обход белых списков маскировкой под WebRTC звонки разрешенных сервисов, таких как Yandex Telemost.
- **[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — обход черных списков маскировкой под трафик браузера Chrome.

Каждая технология подходит для своей задачи и не было места, котрое объединяло бы все эти решения. Хотелось задать всё в одном месте и просто нажать «подключиться».

Поэтому я сделал **FlClashM**. Его задача — стать той самой **одной кнопкой**: провайдер готовит конфигурацию, пользователь нажимает переключатель, и соединение работает в любой сети.

> ⚠️ Проект находится в активной разработке. Некоторые функции ещё дорабатываются, а интерфейс может меняться.

---

## Главные преимущества

### Встроенные узлы прямо в профиле

В отличие от обычных клиентов, FlClashM умеет запускать **специальные узлы прямо из YAML-профиля**. Они выглядят как обычные прокси и участвуют в правилах маршрутизации: один сайт можно направить через ByeDPI, другой — через OlcRTC, а всё остальное — напрямую.

Пример для [ByeDPI](https://github.com/hufrea/byedpi). FlClashM автоматически перебирает стратегии из списка ByeByeDPI и кэширует рабочую.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    mode: auto
    strategy-list: byebyeedpi
    test:
      urls:
        - "https://example.com/"
```

Пример для [OlcRTC](https://github.com/openlibrecommunity/olcrtc).

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    auth:
      provider: jitsi
    room:
      id: "https://meet.example.org/room"
    crypto:
      key: "0123456789abcdef..."
```

Пример для [NaiveProxy](https://github.com/klzgrad/naiveproxy).

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    proxy: "https://user:pass@example.com"
```

[Подробнее о встроенных узлах тут](docs/user-guide/profiles.md)

## Раздельное туннелирование через профиль

Провайдер может задать правила раздельного туннелирования прямо в профиле — какие приложения должны идти через VPN, а какие нет. Поддерживаются точные имена пакетов, маски и регулярные выражения.

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

Можно загружать списки из файлов или URL. Профиль имеет приоритет над ручными настройками.

[Подробнее о раздельном туннелировании тут](docs/user-guide/split-tunneling.md)

---

## Что еще умеет

- **VPN/TUN-подключение** через `mihomo`.
- **Профили** по ссылке, из файла, QR-коду и с Android TV.
- **Режимы работы**: правила, глобальный, прямое соединение.
- **Виджеты** и **плитка быстрых настроек** для управления VPN.
- **Встроенное обновление** с проверкой контрольных сумм.
- **Уведомления** об истечении подписки.
- **Автозапуск** после перезагрузки устройства.
- **Оформление** через подсказки провайдера (хедеры).

---

## Скачать

Готовые сборки публикуются в [GitHub Releases](https://github.com/makriq-org/FlClashM/releases).

| Файл | Описание |
|------|----------|
| `FlClashM-android-universal.apk` | Универсальная сборка |
| `FlClashM-android-arm64-v8a.apk` | 64-битные ARM |
| `FlClashM-android-armeabi-v7a.apk` | 32-битные ARM |
| `FlClashM-android-x86_64.apk` | x86_64 |
| `FlClashM-android-release.aab` | Android App Bundle |

По умолчанию встроенный загрузчик показывает только стабильные версии. Предварительные сборки можно включить в настройках.

---

## Документация

### Для пользователей
- **[Встроенные узлы](docs/user-guide/profiles.md)** — ByeDPI, OlcRTC, NaiveProxy
- **[Раздельное туннелирование](docs/user-guide/split-tunneling.md)** — управление через профиль
- **[Подсказки провайдера](docs/user-guide/provider-hints.md)** — оформление и поведение

### Для разработчиков
- **[Архитектура](docs/development/architecture.md)** — слои и сервисы
- **[Среда выполнения](docs/development/runtime.md)** — обработка профиля и встроенные узлы
- **[Безопасность](docs/development/security.md)** — политика безопасности
- **[Релизы](docs/development/release-contract.md)** — публикация и откат версий
- **[Синхронизация с FlClashX](docs/development/upstream-sync.md)** — обновление базы
- **[Проверка сборки](docs/development/verification.md)** — локальные и CI-проверки

---

## Сборка

Нужны Flutter 3.41.x, JDK 17, Android SDK/NDK и Go 1.26.x.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

---

## Благодарности

FlClashM построен на базе [FlClashX](https://github.com/chen08209/FlClashX) — отличного кроссплатформенного клиента для Clash/Mihomo. Огромное спасибо авторам за проделанную работу и открытый код, без которого этот проект был бы невозможен.

Отдельная благодарность авторам [ByeDPI](https://github.com/hufrea/byedpi), [OlcRTC](https://github.com/openlibrecommunity/olcrtc) и [NaiveProxy](https://github.com/klzgrad/naiveproxy) — без их труда обход блокировок был бы невозможен.

---

## Лицензия

Код приложения распространяется по лицензии GPL-3.0. Сторонние ядра и встроенные исполняемые файлы сохраняют свои исходные лицензии.
