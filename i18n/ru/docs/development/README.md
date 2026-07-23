# Разработка FlClashM

Поддерживаемая цель — Android-форк FlClashX с небольшим контролируемым дрейфом
базы. Новая продуктовая логика размещается в `lib/product/**`; Android-мосты и
неизбежные base-изменения должны оставаться узкими и быть зарегистрированы.

## С чего начать

1. Прочитайте [архитектуру](architecture.md) и определите слой изменения.
2. Для профилей и процессов используйте [runtime-контракт](runtime.md), для
   security-sensitive пути — [политику безопасности](security.md).
3. Перед правкой base-файла проверьте `tool/product_touchpoints.json` и
   `tool/base_drift_allowlist.json`.
4. Запустите набор из [инструкции по проверке](verification.md).

Основной поток данных:

```text
RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan
           -> EngineManager -> EngineAdapter -> Android service / mihomo
```

## Режим cheap-upstream

Живые апстримные экраны остаются в `lib/views/**` и получают минимальные hooks.
Fork-only UI допустим в `lib/product/**` только с записью в `allowedProductUi`.
Механическое копирование base-экрана в product-слой увеличивает будущие
конфликты и не считается изоляцией.

Синхронизация начинается с `upstream/dev` и выполняется в отдельной ветке по
[зафиксированной процедуре](upstream-sync.md). `applicationId`
`com.makriq.flclash` и репозиторий выпуска `makriq-org/FlClashM` входят в
контракт непрерывности и не меняются обычным рефакторингом.

## Версии инструментов

CI использует Flutter 3.41.7, Go 1.26.3, JDK 17 и Android NDK
`28.0.13004108`. `flake.nix` закрепляет совместимое окружение NixOS. Для
воспроизводимой пересборки конкретного runtime-узла дополнительно соблюдайте его
`assets/runtimes/<name>/android/release.txt`: например, OlcRTC сейчас закрепляет
собственную версию Go 1.26.4.
