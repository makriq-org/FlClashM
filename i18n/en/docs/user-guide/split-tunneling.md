# Split tunneling

FlClashM lets you control which apps use VPN and which don't. This can be configured in two ways: manually in app settings or directly in the YAML profile.

## Split tunneling via profile

The provider can specify split tunneling rules directly in the profile. These rules take priority over the user's manual settings.

### Whitelist: only selected apps

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
```

Only the listed apps will use VPN.

### Blacklist: exclude selected apps

```yaml
tun:
  enable: true
  exclude-package:
    - com.android.chrome
    - org.mozilla.firefox
```

The listed apps will not use VPN.

> You cannot use `include-package` and `exclude-package` at the same time.

## Selector formats

In addition to exact package names, wildcards and regular expressions are supported:

| Format | Example | Description |
|--------|---------|-------------|
| Exact name | `com.termux` | Exact match |
| Wildcard | `*.yandex.*` | All Yandex apps |
| Regular expression | `re:^org\.mozilla\..+$` | All Mozilla apps |
| Exclusion | `!ru.yandex.browser` | Exclude from the list |

### Example with wildcards and exclusions

```yaml
tun:
  enable: true
  exclude-package:
    - '*.yandex.*'              # All Yandex apps
    - '!ru.yandex.browser'      # Except Yandex Browser
    - 're:^org\.mozilla\..+$'   # All Mozilla apps
```

## Loading lists from files

Package lists can be stored in separate files:

```yaml
tun:
  enable: true
  include-package-file:
    - lists/allowed-apps.txt
```

Files must contain one package name or selector per line.

## Loading lists from URL

Lists can be fetched via HTTP(S):

```yaml
tun:
  enable: true
  include-package-url: https://example.com/packages.txt
```

The list is cached locally and used when the URL is unavailable.

## How it works

1. FlClashM reads the `tun` section from the profile.
2. Resolves selectors (wildcards, regex) to concrete installed packages.
3. Creates access control rules.
4. These rules take priority over manual settings.

If the profile defines split tunneling, the app settings will show that access control is managed by the profile.
