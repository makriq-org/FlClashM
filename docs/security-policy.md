# Security Policy

## Базовый принцип

Android security policy определяется клиентом `FlClashM`.

Провайдер подписки может передавать:

- metadata
- display hints
- advisory runtime hints

Провайдер не может:

- ослаблять client security floor
- задавать обязательное security-critical поведение через headers

## Текущий контракт

Product-level security boundary теперь выражена типами:

- advisory provider side: `ProviderAdvisoryHints`, `ProviderNetworkHints`, `ProviderRuntimeHints`
- compile result: `CompiledProfilePatch`
- client-enforced policy result: `SecuredProfilePatch`
- runtime hardening flags: `RuntimeSecurityConstraints`

Это означает:

- `ProfileCompiler` только читает advisory hints
- `SecurityPolicy` применяет обязательные client rules и для compile handoff, и для direct runtime updates
- `EngineManager` больше не работает с объединенным “patch+policy” этапом

## Android floor

Текущий Android floor:

- Android runtime идет через VPN/TUN path
- `AndroidSecurityPolicy` принудительно включает TUN на security stage
- тот же `AndroidSecurityPolicy` принудительно включает TUN и для live `updateConfig` path
- runtime plan builder применяет Android tun hardening по `RuntimeSecurityConstraints`
- `AccessControlService` собирает Android VPN access-control client-side из локального `vpnProps.accessControl`
- profile-driven split tunneling из профиля имеет явный client-managed приоритет над manual `vpnProps.accessControl`; explicit include-mode с пустым resolved set не откатывается назад к manual ACL
- file/url-backed package lists ограничены каталогом профилей и кешируются per-profile с fallback только на последнюю валидную локально сохраненную копию
- Android app updater принимает только APK, прошедший SHA256 verification перед installer handoff
- Flutter HTTP path не отключает TLS-проверку глобально; loopback bypass для control-plane остается отдельным proxy-routing правилом, а не `badCertificateCallback=true`
- built-in proxy nodes не могут задавать `listen/server/port` сами: локальный bind и портовая политика принадлежат клиенту
- `olcrtc` nodes не могут задавать `socks.host`/`socks.port`, `mode: srv/gen` или `crypto.key_file`; Android client поддерживает только локальный `mode: cnc`

## Provider headers

- `flclashm-androidsecure` считается advisory hint и не участвует в обязательной policy
- `flclashm-servicename` и `flclashm-serverinfo` остаются display-only hints
- branding/custom view headers не могут менять runtime floor
- display/customization header parsing локализован в `lib/product/subscription/**`
- updater/access-control services не используют provider headers как policy input
- raw provider headers не должны использоваться как product API в base/UI слоях
- provider metadata не может ослабить path validation, checksum verification или profile-vs-manual priority rules
- provider metadata не может ослабить local-bind ограничения `olcrtc` или перевести Android client в server/gen mode
- brand contract и остаточные compatibility boundaries зафиксированы в `docs/branding.md` и `docs/compatibility-boundaries.md`

## Advisory profile hints

- `overrideNetworkSettings=false` разрешает advisory hints влиять на compile result
- `overrideNetworkSettings=true` оставляет за клиентом и network/runtime hints, и `external-controller`

## Границы ответственности

### Клиент решает

- какой security floor обязателен
- какие runtime adapters вообще допустимы
- какие Android ограничения нельзя ослаблять

### Подписка может только подсказывать

- branding metadata
- service/server display hints
- advisory profile settings

## Правила для новых runtime

Перед новой runtime-интеграцией нужно зафиксировать:

1. место в архитектуре
2. контракт
3. security ограничения
4. update path
5. rollback path
