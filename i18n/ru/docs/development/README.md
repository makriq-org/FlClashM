# Для разработчиков

FlClashM — Android-клиент для mihomo. Go backend управляет данными и подключением,
Flutter показывает интерфейс, Android предоставляет системные механизмы.

- [Архитектура](architecture.md) — слои и граница с апстримом.
- [Go backend](go-backend/architecture.md) — API, состояние, хранение и миграция.
- [Среда выполнения](runtime.md) — запуск, внешние узлы и патчи mihomo.
- [Диагностика](diagnostics.md) — локальные журналы и экспорт.
- [Безопасность](security.md) — ограничения профиля и сетевых запросов.
- [Релизы](release-contract.md) — сборка и доставка обновлений.
- [Синхронизация с FlClashX](upstream-sync.md) — обновление базы.
- [Проверка](verification.md) — локальные команды, CI и известные проблемы.

На NixOS окружение задаёт `flake.nix`:

```bash
nix develop -c make dev              # отладочный APK для arm64
nix develop -c make check            # проверки Dart/Flutter и границ форка
nix develop -c make go-check         # host-тесты Go, vet и race detector
```

Правила веток, коммитов и PR — в [AGENTS.md](../../../../AGENTS.md).
Закрепление зависимостей внешних узлов — в
[tool/runtime_go_modules](../../../../tool/runtime_go_modules/README.md).

Переводы могут отставать: [English](../../../en/docs/development/README.md) ·
[中文](../../../zh/docs/development/README.md) · [فارسی](../../../fa/docs/development/README.md).
