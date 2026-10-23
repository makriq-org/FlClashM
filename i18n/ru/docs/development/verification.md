# ✅ Проверка сборки

## 🤖 CI-проверка

`.github/workflows/android-base-verification.yaml` проверяет:

- 🚧 границы продуктового слоя;
- 📦 контракт релизов;
- 🔄 расхождения base-файлов с `upstream/dev`;
- 🧪 тесты `test/product` и `test/tool`;
- 🔒 закрепление внешних GitHub Actions за полными commit SHA;
- 🔍 выборочный статический анализ продуктового и выпускного кода;
- 🏗 Android-сборку для `arm64`.

> [!NOTE]
> При изменении Android/runtime-пути дополнительно собирается `armeabi-v7a`, а `x86_64` запускается на Android Emulator.

Эмуляторный E2E устанавливает debug APK, проверяет наличие всех встроенных runtime-бинарников и запускает ByeDPI через боевой AIDL/process-manager путь. Затем он поднимает настоящий TUN и foreground-службу с локальным профилем `DIRECT`, убивает процесс `:remote`, ждёт восстановления binder-сервиса и повторно запускает core и VPN через поддерживаемый headless AIDL-контракт. Системное VPN-разрешение выдаётся через `ACTIVATE_VPN`: это единственная тестовая предпосылка, потому что системный consent UI намеренно не автоматизируется. Внешняя сеть тесту не нужна.

Автоматический `START_STICKY`-перезапуск `FlVpnService` после гибели общего процесса `:remote` в этот E2E не заявляется: Android восстанавливает binder-сервис, а headless recovery выполняется явной production-командой через AIDL.

При падении workflow сохраняет instrumentation output, `logcat`, список процессов и срезы `dumpsys` для служб, VPN-сети и уведомлений. Проверка покрывает Android-контракт на `x86_64`; работоспособность runtime-бинарников на ARM ABI по-прежнему подтверждается перед выпуском на реальном устройстве.

**Как запускается.** Для рабочих веток основной процесс запускается событием pull request, а `push` используется только для `main`. Отдельный процесс непрерывности выпуска оставлен для ручного запуска: автоматически эта проверка уже входит в основной процесс, поэтому один коммит не создаёт дублирующие наборы проверок. Новый запуск того же pull request отменяет предыдущий незавершённый. Если изменена только посторонняя документация, тяжёлые задания пропускаются.

Отдельный `secret-scan` проверяет Gitleaks все коммиты, добавленные pull request или push в `main`. Версия сканера и SHA-256 его архива зафиксированы в workflow.

## Ревью Codesmith

`.github/workflows/codesmith-review.yaml` запрашивает ревью через
`@codesmith-bot` при открытии PR, новых коммитах, повторном открытии и выходе
из draft. Для каждого HEAD отправляется один комментарий; повторный запуск
workflow не дублирует запрос. Успех задания означает отправку запроса, а не
успешное ревью. Проверка не должна быть обязательным условием мерджа.

Автоматизация включается переменной репозитория `CODESMITH_AUTO_REVIEW=true`
в Settings → Secrets and variables → Actions → Variables. По умолчанию она
выключена. Перед включением нужно проверить условия аккаунта в
[Blacksmith Billing and Usage](https://app.blacksmith.sh/) и подтвердить, что
Codesmith отвечает на упоминания от `github-actions[bot]`. Вызов от человека
подтверждён в [PR #127](https://github.com/makriq-org/FlClashM/pull/127),
но не доказывает поддержку вызовов от бота или постоянный бесплатный доступ.
[Общая документация](https://docs.blacksmith.sh/codesmith/pricing-and-faqs)
описывает оплату agent compute units; отдельные бесплатные условия ревью
через тег в ней не указаны. Платный Autofix этим workflow не включается.

Для PR от OWNER, MEMBER и COLLABORATOR запрос отправляется автоматически.
Для остальных авторов сопровождающий сначала добавляет метку
`codesmith-review`; она разрешает также ревью последующих коммитов этого PR.
Если метку удалить, следующие запросы для внешнего автора прекращаются.
Workflow использует `pull_request_target`, но не скачивает и не исполняет
код PR: выполняется только закреплённый `actions/github-script` с правом
записи комментариев. Сам агент получает код PR как контекст ревью.

Если Codesmith игнорирует комментарии от GitHub Actions, автоматизацию
нельзя считать работающей: следует использовать штатную настройку Blacksmith,
если она доступна в аккаунте. Токен пользователя в репозитории для обхода
этого ограничения не сохраняется.

Для отключения удалить `CODESMITH_AUTO_REVIEW` или установить `false`.
Это останавливает новые запросы; уже запущенные сессии останавливаются в
Blacksmith отдельно. Ручной вызов `@codesmith-bot` остаётся доступным.

## 💻 Локальная проверка

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_actions_pinning.dart
dart tool/check_release_continuity.dart
dart tool/check_base_drift.dart
flutter test test/product test/tool
flutter analyze --fatal-infos lib/product test/product test/tool
```

## 📱 Android-сборка

Нужны: Android SDK 37.0, NDK `28.0.13004108` + `28.2.13676358`, JDK 17.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```

> [!WARNING]
> Эмуляторный E2E не заменяет предрелизную проверку ARM ABI на реальном Android-устройстве.

---

> 🌍 Другие языки: [English](../../../en/docs/development/verification.md) · [中文](../../../zh/docs/development/verification.md) · [فارسی](../../../fa/docs/development/verification.md)
