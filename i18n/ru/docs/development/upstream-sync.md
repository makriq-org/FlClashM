# Синхронизация с FlClashX

База обновляется из `upstream/dev`. Flutter-интеграции форка живут в
`lib/product/**`, бизнес-логика подключения — в `core/backend/**`.
Остальные отличия от апстрима учитываются явно.

1. Создать ветку от целевой ветки форка и выполнить `make fetch-upstream`.
2. Выполнить `git merge upstream/dev` и разрешить конфликты. Имя Dart-пакета
   остаётся `flclashx`; переписывать импорты не нужно. Git `rerere` переиспользует
   ранее сохранённые разрешения конфликтов.
3. Сразу запустить `dart tool/check_base_drift.dart`. Если upstream недоступен,
   передать `--merge-base=<sha>` или `BASE_DRIFT_MERGE_BASE`.
4. Новые обращения base к product зарегистрировать в `tool/product_touchpoints.json`.
   Прочие необходимые изменения base объяснить в `tool/base_drift_allowlist.json`.
   Экраны `lib/views/**` сохранять с минимальными хуками без копий в product.
5. Перед PR выполнить `make check` и `make go-check` в окружении `nix develop`.
   Изменения Android/runtime проверить по [инструкции](verification.md).

При выборе версии учитывается пользовательский эффект и форка, и апстрима.
Синхронизация без видимого эффекта входит в ближайший выпуск. Изменения runtime
сначала выпускаются через `-preN` с проверкой на реальных Android ABI.

Правила коммитов, PR и релизов — в [AGENTS.md](../../../../AGENTS.md).
