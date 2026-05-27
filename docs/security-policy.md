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
- Android VPN access-control по-прежнему собирается client-side из локального `vpnProps.accessControl`

## Provider headers

- `flclashx-androidsecure` считается legacy и не участвует в обязательной policy
- `flclashx-servicename` и `flclashx-serverinfo` остаются display-only hints
- branding/custom view headers не могут менять runtime floor

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
