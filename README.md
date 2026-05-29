<div>

[**English**](README_EN.md)

</div>

## FlClashM

[![Downloads](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Last Version](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![License](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)

`FlClashM` — Android-only продуктовый клиент на базе `FlClashX`, с сохранением Android continuity относительно `FlClash-my`.

Мобильный вид:

<p style="text-align: center;">
    <img alt="mobile" src="snapshots/mobile.gif">
</p>

## Добавленный функционал

🛠️ Исправлены стандартные настройки: режим поиска процессов вкл, режим tun вкл, режим системного прокси выкл, режим отображения списка прокси list, изменена работа камеры при добавлении подписки через QR.

📱 **Поддержка 120Гц дисплеев на Android:** Добавлена поддержка высокочастотных дисплеев (120Гц) на устройствах Android для более плавных анимаций и прокрутки.

🗑️ **Очистка данных приложения:** Добавлена кнопка "Очистить данные" в настройках приложения, которая удаляет все профили из папки profiles. Полезно для устранения неполадок или сброса приложения.

🇷🇺 Переработана локаль в приложении под продуктовый Android-фокус

✈️ Передача HWID в панель (Работает только с <a href="https://github.com/remnawave/panel">Remnawave</a>)

💻 Добавлен новый виджет "Анонсы". Передаёт анонсы из панели в виджет. (Работает только с <a href="https://github.com/remnawave/panel">Remnawave</a>)

📺 Оптимизация управления на Android TV

- добавлена кнопка "Вставить" для меню добавления подписки по ссылке
- добавлена кнопка выбора профиля
- добавлена передача профиля с мобильного приложения через QR-код

🪪 Переработана карточка профиля на странице профиля и виджет на главной:

- Используется индикатор объёма трафика с изменением цвета (не отображается, если трафик неограничен).
- Отображается дата окончания подписки (если год — 2099, выводится «Ваша подписка вечная»).
- Добавлена новая кнопка «Поддержка» в профиле, которая подтягивает supportUrl с панели.
- Параметр autoupdateinterval для профиля теперь корректно передаётся с панели.
- Добавлен виджет "MetaInfo". Передаёт параметры с подписки на виджет. Сколько трафика осталось, когда заканчивается подписка, имя профиля, и крупно отображает сколько дней до окончании подписки осталось (за 3 дня до окончания).
- Добавлен виджет "serviceInfo". Передаёт название вашего сервиса. Можно передать дополнительно хедер `flclashx-servicelogo` для кастомного лого (поддерживается ссылка svg/png), дополнительно по клику открыватеся ссылка на поддержку (supportURL)
- Добавлен виджет "changeServerButton". По клику перенаправляет на страницу прокси.

### Добавлен парсинг кастомных хедеров со страницы подписки:

Legacy namespace `flclashx-*` здесь сохранен намеренно ради совместимости с существующими подписками. Для новых product surface используется бренд `FlClashM`.

<details>
<summary><strong>flclashx-widgets</strong></summary>

Выстраивает виджеты в порядке, полученным с подписки

|       Значение       | Виджет                                                      |
| :------------------: | ----------------------------------------------------------- |
|      `announce`      | Анонсы                                                      |
|    `networkSpeed`    | Скорость сети                                               |
|   `outboundModeV2`   | Режим работы прокси (новый вид)                             |
|    `outboundMode`    | Режим работы прокси (старый вид)                            |
|    `trafficUsage`    | Использование трафика                                       |
|  `networkDetection`  | Определение локации и IP                                    |
|     `tunButton`      | Legacy desktop widget, в Android-only релизах не используется |
|     `vpnButton`      | Кнопка VPN (только Android)                                 |
| `systemProxyButton`  | Legacy desktop widget, в Android-only релизах не используется |
|     `intranetIp`     | Локальный IP-адрес                                          |
|     `memoryInfo`     | Использование памяти                                        |
|      `metainfo`      | Информация о подписке                                       |
| `changeServerButton` | Кнопка смены сервера                                        |
|    `serviceInfo`     | Информация о сервисе (работает только с header flclashx-servicename) |

Использование:

```bash
flclashx-widgets: announce,metainfo,outboundModeV2,networkDetection
```
</details>

<details>
<summary><strong>flclashx-view</strong></summary>

Настраивает вид страницы прокси, полученным с подписки

| Значение | Описание                            | Возможные значения                |
| :------: | ----------------------------------- | --------------------------------- |
|  `type`  | Режим отображения                   | `list`,`tab`                      |
|  `sort`  | Тип сортировки                      | `none`,`delay`,`name`             |
| `layout` | Макет                               | `loose`,`standard`,`tight`        |
|  `icon`  | Стиль иконок (для list-отображения) | `none`,`icon`          |
|  `card`  | Размер карточки                     | `expand`,`shrink`,`min`,`oneline` |

Использование:

```bash
flclashx-view: type:list; sort:delay; layout:tight; icon:icon; card:shrink
```
</details>

<details>
<summary><strong>flclashx-custom</strong></summary>

Управляет состоянием применения стилей для Dashboard и ProxyView

| Значение | Описание                                                |
| :------: | ------------------------------------------------------- |
|  `add`   | Стиль страницы прокси и виджеты применяются только при первом добавлении подписки |
| `update` | Стиль страницы прокси и виджеты применяются каждый раз при обновлении подписки    |

Использование:

```bash
flclashx-custom: update
```
</details>

<details>
<summary><strong>flclashx-denywidgets</strong></summary>

При true — запрещает редактировать страницу Dashboard. Имеет значение true/false.

Использование:

```bash
flclashx-denywidgets: true
```
</details>

<details>
<summary><strong>flclashx-servicename</strong></summary>

Название вашего сервиса, отображаемое в виджете ServiceInfo.

Использование:

```bash
flclashx-servicename: FlClashM
```
</details>

<details>
<summary><strong>flclashx-servicelogo</strong></summary>

Ваш логотип, используемый в виджете ServiceInfo (работает только с активным хедером flclashx-servicename). Поддерживает png/svg.

Использование:

```bash
flclashx-servicelogo: https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/remnawave.svg
```
</details>

<details>
<summary><strong>flclashx-serverinfo</strong></summary>

Название прокси-группы для отображения в виджете ChangeServerButton. Виджет показывает активный сервер из указанной группы с флагом страны, пингом и кнопкой для быстрого переключения. Если не передаётся — работает фолбек на «Изменить сервер»

**Отображаемые элементы:**
- Флаг страны (автоматически извлекается из имени прокси, если отсутствует — фолбек иконка)
- Название активного сервера
- Текущий пинг с цветовой индикацией (зелёный < 600ms, оранжевый >= 600ms, красный — timeout)
- Кнопка быстрого перехода на страницу прокси

Использование:

```bash
flclashx-serverinfo: Proxy
```
</details>

<details>
<summary><strong>flclashx-background</strong></summary>

Устанавливает пользовательское фоновое изображение для приложения. Укажите прямую ссылку на изображение.

**Рекомендации для изображения:**
- Формат: PNG, JPG или WebP
- Разрешение: 1080x1920 или выше для мобильных устройств
- Размер файла: Желательно до 2МБ для лучшей производительности
- Содержание: Используйте изображения с тонкими узорами или градиентами; избегайте слишком ярких или загруженных изображений
- Контраст: Обеспечьте хорошую читаемость текста на фоне

Использование:

```bash
flclashx-background: https://example.com/background.jpg
```
</details>

<details>
<summary><strong>flclashx-settings</strong></summary>

Управление настройками приложения через хедер (с возможностью переопределения со стороны клиента). По умолчанию все параметры выключены. Если вы передаёте параметр, то он будет включён. Если не передаёте — останется выключенным.

|   Параметр    | Описание                                                 | По умолчанию |
| :-----------: | -------------------------------------------------------- | :----------: |
|  `autostart`  | Автоматически запускать прокси при запуске приложения    | ❌ Выкл      |
| `autoupdate`  | Автоматически проверять обновления приложения            | ❌ Выкл      |

Desktop-only флаги `minimize`, `autorun` и `shadowstart` в Android-only продукте считаются legacy и игнорируются.

Переопределение на стороне клиента: Пользователи могут включить «Переопределить настройки провайдера» в настройках приложения, чтобы применять свою локальную конфигурацию вместо настроек из подписки.

Использование:

```bash
flclashx-settings: autostart, autoupdate
```
</details>

<details>
<summary><strong>flclashx-globalmode</strong></summary>

Данный хедер при FALSE позволяет скрыть все настройки режима прокси из клиента (трей, страница прокси, виджеты смены режима)

Использование:
```bash
flclashx-globalmode: false
```
</details>

<details>
<summary><strong>flclashx-hex</strong></summary>

Данный хедер позволяет настроить тему в приложении, возможность передать основной цвет, вариант, и выбрать "Чисто черный режим" параметром `pureBlack`

Варианты:
|   Вариант    | Название|
| :-----------: | ------ |
|  `tonalSpot`   | Тональный акцент|
|   `fidelity`   | Точная передача |
| `monochrome` | Монохром |
|  `neutral`  | Нейтральные |
| `vibrant`  | Яркие |
| `expressive`  | Экспрессивные |
| `content`  | Контентная тема |
| `rainbow`  | Радужные |
| `fruitSalad`  | Фруктовый микс |

Использование:
```bash
flclashx-hex: FF5733
flclashx-hex: FF5733:vibrant
flclashx-hex: FF5733:vibrant:pureblack
```
Так-же можно параметры использовать по отдельности:
```bash
flclashx-hex: FF5733
flclashx-hex: vibrant
flclashx-hex: pureblack
```
HEX-коды стандартных тем:
|   HEX    | ЦВЕТ|
| :-----------: | ------ |
|  `795548`   | Brown (Коричневый)|
|   `03A9F4`   | Light Blue (Светло-голубой) - по умолчанию |
| `FFFF00` | Yellow (Желтый) |
|  `BBC9CC`  | Light Blue Grey (Светло-серо-голубой) |
| `ABD397`  | Light Green (Светло-зеленый) |
| `D8C0C3`  | Light Pink (Светло-розовый) |
| `665390`  | Deep Purple (Темно-фиолетовый) |
</details>

<details>
<summary><strong>flclashx-androidsecure</strong></summary>

В `FlClashM` этот header больше не используется как обязательная Android security policy.

Он считается legacy hint и не должен менять security-critical поведение клиента.

Использование:
```bash
flclashx-androidsecure: true
```
</details>

### Переопределение настроек конфигурации
По умолчанию следующие параметры конфигурации, полученные от подписки, **не переопределяются** клиентом:

- `allow-lan` - Разрешить подключения из локальной сети
- `ipv6` - Включить поддержку IPv6
- `find-process-mode` - Режим поиска процессов
- `tun-stack` - Сетевой стек режима TUN
- `mixed-port` - Смешанный порт для HTTP/SOCKS прокси

**Переопределение на стороне клиента:** Пользователи могут включить "Переопределить настройки провайдера" или "Переопределить сетевые настройки" в настройках приложения, чтобы применять свою локальную конфигурацию вместо настроек из подписки. Это полезно, когда нужны кастомные сетевые настройки.

## Использование

### Android

Поддерживаются следующие действия:

```bash
 com.makriq.flclash.action.START

 com.makriq.flclash.action.STOP

 com.makriq.flclash.action.CHANGE
```

## Скачать

Релизные артефакты публикуются только для Android:

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

<a href="https://github.com/makriq-org/FlClashM/releases"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" width="200px"/></a>

## Star

<p style="text-align: center;">
Самый простой способ поддержать разработчиков — нажать на звездочку (⭐) в верхней части страницы.<br>
Если хотите поддержать копеечкой, то можно <a href="https://t.me/tribute/app?startapp=dtyh">сделать это тут.</a></p>

**TON USDT:** `UQDSfrJ_k1BdsknhdR_zj4T3Is3OdMylD8PnDJ9mxO35i-TE`
