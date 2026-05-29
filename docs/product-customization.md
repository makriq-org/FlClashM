# Product Customization Contract

## Цель

Provider-driven display/customization hints должны проходить через узкий product seam, а не размазываться по `controller/providers/views/services`.

Текущий seam собран в `lib/product/subscription/**`.

## Контракт

Главная точка входа:

- `ProductProviderAdvisory.fromProfile`
- `ProductProviderAdvisory.fromHeaders`

На выходе base/UI consumer получает:

- `display: ProductDisplayHints`
  - `announcement`
  - `supportUrl`
  - `serviceName`
  - `serviceLogoUrl`
  - `serverInfoGroupName`
  - `backgroundUrl`
  - `globalModeEnabled`
  - `newDashboard`
  - `denyDashboardEditing`
- `customization: ProductCustomizationHints`
  - trigger `add|update`
  - advisory app settings
  - advisory theme hint
  - advisory dashboard layout
  - advisory proxies view hint
- `notices: ProductNoticeHints`
  - HWID-related display notices

Отдельно product layer держит:

- `ProductProviderAdvisory.mergeForRefresh`
  - merge policy для update path
  - volatile advisory headers очищаются здесь, а не в controller/UI
  - notice headers (`announce`, `support-url`, HWID notices) не должны залипать после refresh

## Правила размещения

- Raw header keys допустимы только:
  - в transport boundary (`Profile.update`)
  - в product parser/normalizer (`lib/product/subscription/**`)
- `controller/providers/views/services` не должны знать конкретные `flclashm-*` header names.
- Base/UI consumer должен использовать typed advisory data или thin selectors.
- Новые provider-driven display/customization rules добавляются в `lib/product/subscription/**`, а не точечно в widgets.
- `effectiveNewDashboard` считается derived state: явный user override важнее advisory `flclashm-newboard`.

## Security Boundary

- Display/customization hints остаются advisory.
- Они не ослабляют `SecurityPolicy`, Android runtime floor или engine selection rules.
- Provider может подсказывать branding/view behavior, но не менять security-critical поведение.
