# Security Policy

## Базовый принцип

Android security policy определяется клиентом `FlClashM`.

Провайдер подписки может передавать:

- metadata
- display hints
- advisory hints

Провайдер не может:

- ослаблять client security floor
- задавать обязательное security-critical поведение через headers

## Что уже закреплено

### 1. Android policy вынесена в `AndroidSecurityPolicy`

Это single point для Android runtime guardrails.

### 2. `flclashx-androidsecure` больше не является источником обязательной policy

В `FlClashM` этот header считается legacy provider hint и не должен менять security-critical поведение клиента.

Причина:

- security policy нельзя делегировать подписке
- это ломает предсказуемость клиента
- это мешает безопасной эволюции Android runtime

### 3. Android runtime floor задаётся клиентом

Текущий минимальный floor:

- Android runtime идёт через VPN/TUN path
- platform policy применяется на стороне клиента во время сборки runtime config
- release pipeline публикует только Android-артефакты

### 4. Android access control merge остаётся client-side

Android VPN access-control для runtime старта собирается клиентом из локального `vpnProps.accessControl`.

Это значит:

- provider headers не могут подменить список allow/deny приложений
- `flclashx-servicename` и `flclashx-serverinfo` остаются display-only hints и не участвуют в access/update policy
- runtime получает уже собранный client-side policy payload
- future updater/install flow не должен обходить этот boundary

## Границы ответственности

### Клиент решает

- какие Android runtime ограничения обязательны
- какие параметры можно менять пользователю
- какие runtime adapters допускаются

### Подписка может только подсказывать

- branding metadata
- service label hints
- server info hints
- advisory profile settings

## Правила для будущих изменений

Перед любой новой runtime-интеграцией нужно зафиксировать:

1. место в архитектуре
2. контракт
3. security ограничения
4. update path
5. rollback path

## Технический долг

Следующий этап:

- вынести полноценный `SecurityPolicy` из общего `GlobalState`
- разделить advisory provider hints и обязательные client rules на уровне типов, а не строковых header key
