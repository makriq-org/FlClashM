# 🎯 Split Tunneling

Split tunneling answers a simple question: **which apps go through the VPN and which go directly**. There are two ways to set it up:

- 🖐 **manually** — in the app settings;
- 📄 **via profile** — the provider defines the rules right in the YAML.

> [!NOTE]
> Rules from the profile take **priority** over manual settings. If the profile defines split tunneling, the app settings will show that access control is managed by the profile.

---

## 📄 Configuration via profile

Rules live in the `tun` section. There are two mutually exclusive modes.

### ✅ Whitelist — only selected apps

**Only** the listed apps go through the VPN; everything else goes directly.

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
```

### ⛔ Blacklist — exclude selected apps

**Everything except** the listed apps goes through the VPN.

```yaml
tun:
  enable: true
  exclude-package:
    - com.android.chrome
    - org.mozilla.firefox
```

> [!WARNING]
> `include-package` and `exclude-package` **cannot** be used at the same time.

---

## 🧬 Selector formats

Besides exact package names, wildcards and regular expressions are supported:

| Format | Example | What it means |
|--------|---------|---------------|
| 🎯 Exact name | `com.termux` | Exact package match |
| ✳️ Wildcard | `*.yandex.*` | All Yandex apps |
| 🔤 Regex | `re:^org\.mozilla\..+$` | All Mozilla apps |
| 🚫 Exclusion | `!ru.yandex.browser` | Remove from the list |

They can be combined — for example, "all of Yandex except the browser, plus all of Mozilla":

```yaml
tun:
  enable: true
  exclude-package:
    - '*.yandex.*'              # All Yandex apps
    - '!ru.yandex.browser'      # Except Yandex Browser
    - 're:^org\.mozilla\..+$'   # All Mozilla apps
```

---

## 📥 Lists from files and URLs

Long lists are conveniently kept outside — one package name or selector per line.

**From a file:**

```yaml
tun:
  enable: true
  include-package-file:
    - lists/allowed-apps.txt
```

**From a URL over HTTP(S):**

```yaml
tun:
  enable: true
  include-package-url: https://example.com/packages.txt
```

> [!NOTE]
> A URL list is cached locally and used if the address becomes unavailable.

---

## ⚙️ How it works under the hood

1. 📖 FlClashM reads the `tun` section from the profile.
2. 🔎 Resolves selectors (wildcards, regex) into specific installed packages.
3. 🧱 Builds access-control rules.
4. 🏆 These rules take priority over manual settings.

---

> 📎 What the "managed by profile" indicator shows exactly and why it reads a snapshot of the VPN service rather than the current core config — in [runtime](../development/runtime.md#-android-vpn-applied-options-snapshot).
>
> 🌍 Other languages: [Русский](../../../ru/docs/user-guide/split-tunneling.md) · [中文](../../../zh/docs/user-guide/split-tunneling.md) · [فارسی](../../../fa/docs/user-guide/split-tunneling.md)
