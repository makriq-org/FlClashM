# Runtime

## Цепочка

Runtime слой подготавливается через явную product chain:

`RawProfile -> ProfileCompiler -> SecurityPolicy -> RuntimePlan`

После этого lifecycle идет через:

`EngineManager -> EngineAdapter`

## Текущее состояние

- `RawProfile` живет в `lib/product/compile/raw_profile.dart`
- `ProductProfilePipeline` живет в `lib/product/compile/product_profile_pipeline.dart`
- `ProfileCompiler` выдает `CompiledProfilePatch`
- `AndroidSecurityPolicy` превращает его в `SecuredProfilePatch`
- `RuntimePlan` строится уже после security stage
- `EngineManager` вызывает стадии в явном порядке `compile -> security -> runtimePlan`
- direct `updateConfig` path тоже проходит через product security floor до adapter bridge
- `RuntimePlan.runtime` остается явным, но product registry в `FlClashM` резолвит только `mihomo`
- `RuntimePlan.files` несет runtime artifacts для built-in proxy nodes
- `RuntimePlan.builtInProxyNodes` несет typed планы локальных встроенных узлов
- `RuntimePlan.profileAccessControl` несет normalized profile-driven split tunneling override для Android VPN handoff
- `RuntimeRegistry` остается allowlist только для main engine registrations
- `BuiltInProxyRegistry` держит allowlist built-in proxy node types и их availability/update/rollback guardrails
- `MihomoEngineAdapter` остается default supported engine и production baseline
- `BuiltInProxySupervisor` оркестрирует lifecycle built-in proxy nodes вокруг `MihomoEngineAdapter`
- `NaiveProxyNodeController` держит multi-instance `naiveproxy` процессы и отдает `clashCore` локальные SOCKS5 listeners как обычные profile nodes
- Android VPN start/stop path для `mihomo` проходит через `AccessControlService -> AndroidRuntimeAccessPolicy`
- access-control snapshot для `mihomo` подается в adapter через runtime composition boundary, а не читается внутри него напрямую
- pending `mihomo` core update применяется через transactional swap с rollback на предыдущий binary path
- pending `naiveproxy` update stage-ится как shared binary swap через `.pending -> active -> .rollback` boundary в app data
- `mihomo` start path считает foreground title best-effort и откатывает listener/VPN handoff при неуспешном старте
- `mihomo` start/stop path теперь так же учитывает built-in proxy node start/stop/rollback
- `EngineManager` читает runtime start time у adapter и на fresh attach, и после stop failure boundary, чтобы reattach state не дрейфовал; при недоступном probe после успешного `start` он падает назад на локальный timestamp, а не роняет старт
- Android always-on/cold-start path теперь поднимает сохраненные runtime nodes до `Core.quickStart`

## Контракты

### `RawProfile`

Вход:

- профиль
- runtime config после локального script/evaluate path

Выход:

- нормализованный профиль
- `ProviderAdvisoryHints`
- `groupDescriptions`

### `ProfileCompiler`

Вход:

- `RawProfile`
- локальный patch config
- локальные override flags

Выход:

- `CompiledProfilePatch`
- advisory-merged metadata без client hardening

### `SecurityPolicy`

Вход:

- `CompiledProfilePatch`
- platform/client context

Выход:

- `SecuredProfilePatch`
- `RuntimeSecurityConstraints`

### `RuntimePlan`

Вход:

- `RawProfile`
- `SecuredProfilePatch`
- runtime patch config после tun-access resolution

Выход:

- полный config для engine setup
- `RuntimeSelection` для main engine
- `builtInProxyNodes` для встроенных локальных узлов
- runtime files для node-specific handoff
- normalized Android split-tunneling policy и `profileAccessControl` override
- metadata для UI handoff

### `EngineManager`

Ответственность:

- lifecycle engine/runtime
- orchestration adapters через `RuntimeRegistry`
- restart/update boundaries
- cold-start snapshot refresh
- start-time sync для reattach/cold-start recovery boundary
- fail-fast guardrails для unsupported runtime selection

### `EngineAdapter`

Ответственность:

- конкретный bridge для runtime
- скрыть low-level детали `clashCore` / Android service path / cold-start persistence
- брать уже вычисленный access-control handoff из product service, а не собирать policy локально
- локально закрывать rollback/cleanup внутри runtime start/stop/update boundary, а не оставлять partial state наружу

## Baseline `mihomo`

На конец этапа 5 `mihomo` считается production baseline со следующими гарантиями:

- pending binary update либо целиком активируется, либо откатывается к предыдущему core с сохранением `.pending` для следующей попытки
- runtime reattach использует `readStartTime` самого adapter, а не только локальный `EngineManager` timestamp
- неуспешный `start` не должен оставлять висящий listener без VPN handoff
- если rollback/cleanup после failed `start` или failed pending update сам ломается, это поднимается наружу как ошибка, а не маскируется `false`
- `stop` и restart-prep не зависят от одного transport path: teardown/restart делаются best-effort по обеим сторонам boundary
- cold-start persistence и runtime attach boundary зафиксированы product/runtime tests, а не только общими manager tests

## Текущие регистрации

- `mihomo`
  - default engine
  - supported
  - hardened production baseline для Android lifecycle/recovery/update path
  - update path: bundled Android core через `setup.dart` -> repo-root `libclash/android`, независимо от `core/` working directory
  - rollback path: bundled core + existing cold-start snapshot
- `naiveproxy`
  - supported built-in proxy node type
  - integration contract: профиль описывает `naiveproxy` через обычный `proxies` entry с `type: naiveproxy`
  - routing contract: узел сохраняет свое имя после compile stage, поэтому его можно включать в обычные `proxy-groups` и использовать в правилах без отдельного runtime режима
  - config contract: built-in node обязан иметь `name` и `proxy`; client сам владеет `listen`, `server` и `port`
  - update path: `setup.dart` вытягивает pinned stable release `v148.0.7778.96-5` из официальных plugin APK assets и пакует `libnaive.so` в bundled Flutter assets
  - activation path: compiler переписывает built-in node в локальный SOCKS5 proxy entry и кладет runtime artifact в `RuntimePlan.files`; `NaiveProxyNodeController` пишет per-node `config.json`, рестартует только затронутые процессы и откатывает node config/process к предыдущему commit state, если `core.setupRuntimePlan` не применился
  - bridge path: Android VPN/TUN остается на текущем `clashCore` seam, который потребляет локальные SOCKS5 listeners `naiveproxy`
  - rollback path: failed pending activation восстанавливает предыдущий shared binary и сохраняет `.pending` для следующей попытки; failed profile apply откатывает только staging затронутых nodes
  - cold-start path: adapter сохраняет runtime-node manifest, а `FlVpnService` поднимает нужные nodes до `Core.quickStart`
- `olcrtc`
  - supported built-in proxy node type
  - integration contract: профиль описывает `olcrtc` через обычный `proxies` entry с `type: olcrtc`
  - routing contract: узел сохраняет свое имя после compile stage и используется в обычных `proxy-groups`/`rules`
  - config contract: built-in node всегда запускается как `mode: cnc`; client сам владеет `socks.host`, `socks.port`, `listen`, `server` и `port`; `crypto.key_file` в v1 запрещен
  - update path: `setup.dart` собирает pinned commit `5dd6822d807e3352fe4452a3b071e043d958a020` из `openlibrecommunity/olcrtc` в bundled Android assets
  - activation path: compiler переписывает built-in node в локальный SOCKS5 proxy entry и кладет `config.yaml` в `RuntimePlan.files`; `OlcRtcNodeController` пишет per-node config, рестартует только затронутые процессы и откатывает node config/process к предыдущему commit state
  - bridge path: Android VPN/TUN остается на текущем `clashCore` seam, который потребляет локальные SOCKS5 listeners `olcrtc`
  - rollback path: failed pending activation восстанавливает предыдущий shared binary и сохраняет `.pending` для следующей попытки; failed profile apply откатывает только staging затронутых nodes
  - cold-start path: общий runtime-node manifest теперь объединяет `naiveproxy` и `olcrtc`, а `FlVpnService` поднимает нужные nodes до `Core.quickStart`
- `byedpi`
  - supported built-in proxy node type
  - integration contract: профиль описывает `byedpi` через обычный `proxies` entry с `type: byedpi`
  - routing contract: узел сохраняет свое имя после compile stage и используется в обычных `proxy-groups`/`rules`
  - config contract: `mode: manual` принимает строку `args`; `mode: auto` принимает `strategies` или `strategy-list: byebyeedpi` и обязательно `test.urls`
  - strategy contract: строки совместимы с ByeByeDPI, то есть это аргументы `ciadpi` без имени исполняемого файла; поддерживается подстановка `{sni}` из `test.sni`
  - update path: `setup.dart` собирает pinned commit `ba532298de7b28cfe854aea83d061369d13ca290` из `hufrea/byedpi` в bundled Android assets и копирует pinned GPL-3.0 список стратегий из `romanvht/ByeByeDPI`
  - activation path: compiler переписывает built-in node в локальный SOCKS5 proxy entry и кладет `config.json` в `RuntimePlan.files`; `ByedpiNodeController` пишет per-node config, выбирает стратегию, кэширует рабочую стратегию и откатывает node config/process к предыдущему commit state
  - bridge path: Android VPN/TUN остается на текущем `clashCore` seam, который потребляет локальный SOCKS5 listener `byedpi`
  - rollback path: failed pending activation восстанавливает предыдущий shared binary и сохраняет `.pending` для следующей попытки; failed profile apply откатывает только staging затронутых nodes
  - cold-start path: общий runtime-node manifest сохраняет выбранные аргументы byedpi; `FlVpnService` поднимает узел до `Core.quickStart`

## Ограничения

- Provider hints не определяют runtime floor.
- `naiveproxy` listener path определяется клиентом, а не profile metadata.
- `olcrtc` local SOCKS bind определяется клиентом, а не profile metadata.
- `byedpi` local SOCKS bind определяется клиентом; profile не может задавать `ip`, `port`, `listen` или `server`.
- `byedpi mode: auto` не делает скрытых проверок: URL проверки задаются только в профиле через `test.urls`.
- built-in proxy nodes поддерживаются только в `proxies`, а не в `proxy-providers`.
- Unsupported runtime/node нельзя включить без registry change.
- Runtime orchestration не должна разъезжаться между UI/controller/service bridge.
- split tunneling/access-control orchestration не должна обходить `AccessControlService`.
- raw profile читается напрямую из YAML на клиенте, чтобы compile stage видел built-in proxy nodes и client-only Android fields до handoff в core.
