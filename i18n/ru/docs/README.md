# Документация FlClashM

Здесь описан поддерживаемый Android-продукт FlClashM. Кроссплатформенные файлы,
унаследованные от FlClashX, могут оставаться в дереве, но не считаются обещанием
выпусков для других платформ.

## Пользователям

Начните с [руководства пользователя](user-guide/README.md). В нём собраны:

- [установка, добавление профиля и первое подключение](user-guide/getting-started.md);
- [контракт встроенных узлов](user-guide/profiles.md): ByeDPI, OlcRTC и NaiveProxy;
- [раздельное туннелирование Android-приложений](user-guide/split-tunneling.md);
- [подсказки провайдера подписки](user-guide/provider-hints.md).

Обычные YAML-профили Mihomo не обязаны использовать расширения FlClashM. Если
профиль содержит встроенные узлы или управляет списком Android-приложений,
ориентируйтесь на текущую документацию и [CHANGELOG](../../../CHANGELOG.md):
предварительные версии могут уточнять строгую схему.

## Разработчикам

Начните с [обзора разработки](development/README.md), затем используйте разделы
по задаче:

- [архитектура и границы слоёв](development/architecture.md);
- [компиляция профиля и runtime](development/runtime.md);
- [модель доверия и защиты](development/security.md);
- [контракт Android-релиза и обновлений](development/release-contract.md);
- [синхронизация с `upstream/dev`](development/upstream-sync.md);
- [локальные и CI-проверки](development/verification.md).

## Источники истины

Документация объясняет контракт, а исполняемые ограничения закреплены в коде:

- схема профиля — `lib/product/compile/**` и тесты `test/product/compile/**`;
- жизненный цикл встроенных узлов — `lib/product/runtime/**`, Android service и
  `test/product/runtime/**`;
- релизный контракт — `tool/release_continuity_baseline.json`,
  `tool/release_contract.dart` и `.github/workflows/build.yaml`;
- границы форка — `tool/product_touchpoints.json`,
  `tool/base_drift_allowlist.json` и соответствующие проверки.

Если текст расходится с гейтом или строгим валидатором, исправляется текст или
контракт отдельным осознанным изменением; обходить проверку ради примера нельзя.
