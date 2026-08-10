# 🎨 Provider Hints

The provider can send a set of hints prefixed with `flclashm-*` in the subscription response headers. They tune the app's **appearance and behavior**, but **cannot weaken security**.

## 🔧 How it works

The subscription returns a YAML profile in the response body, and the hints in the HTTP headers. FlClashM applies them when a profile is added or updated (see [`flclashm-custom`](#-behavior)).

> [!NOTE]
> Several headers' values are **base64**-encoded (marked below). Boolean headers accept `true`/`false`.

---

## 🖌 Appearance

| Header | Value | What it does |
|--------|-------|--------------|
| `flclashm-background` | URL | Background image |
| `flclashm-hex` | `HEX[:variant][:pureblack]` | Color theme (see below) |

### `flclashm-hex` format

- **`HEX`** — the color: 6 or 8 hex characters, with or without `#` (`5c6bc0`, `#5c6bc0`). 8 characters include an alpha channel.
- **`variant`** *(optional)* — a Material 3 scheme name: `tonalSpot`, `fidelity`, `monochrome`, `neutral`, `vibrant`, `expressive`, `content`, `rainbow`, `fruitSalad`.
- **`pureblack`** *(optional)* — a pure-black background (handy for OLED).

```text
flclashm-hex: 5c6bc0                    # color only
flclashm-hex: #5c6bc0:vibrant           # color + scheme
flclashm-hex: 5c6bc0:vibrant:pureblack  # color + scheme + black background
```

---

## 🏠 Home screen

| Header | Value | What it does |
|--------|-------|--------------|
| `flclashm-widgets` | list | Order and set of dashboard widgets |
| `flclashm-view` | `key:value;…` | Proxies page layout (see below) |
| `flclashm-newboard` | `true`/`false` | Enable the new dashboard ("New look") |
| `flclashm-denywidgets` | `true`/`false` | Forbid editing the home screen |

### `flclashm-view` format

`key:value` pairs separated by `;`. Every key is optional — set only the ones you need.

| Key | Allowed values |
|-----|----------------|
| `type` | `list`, `tab` |
| `sort` | `none`, `delay`, `name` |
| `layout` | `loose`, `standard`, `tight` |
| `icon` | `icon` (or `standard`), `none` |
| `card` | `expand`, `shrink`, `min`, `oneline` |

```text
flclashm-view: type:tab;sort:delay;card:min
```

---

## 🏷 Service info

> [!IMPORTANT]
> The values of these three headers are passed as **base64**.

| Header | Value | What it does |
|--------|-------|--------------|
| `flclashm-servicename` | base64 | Service name |
| `flclashm-servicelogo` | base64 (URL) | Service logo |
| `flclashm-serverinfo` | base64 | Name of the group with server info |

---

## ⚙️ Settings

| Header | Value | What it does |
|--------|-------|--------------|
| `flclashm-settings` | comma-separated flags | Pre-fill app settings |
| `flclashm-globalmode` | `false` hides | Whether to show the global-mode selector (shown by default) |

### `flclashm-settings` flags

| Flag | What it enables |
|------|-----------------|
| `autostart` | Auto-start / auto-connect (including after reboot) |
| `autoupdate` | Automatic update checking |
| `autorun` | Launch the app on system start *(desktop)* |
| `shadowstart` | Silent (background) launch |
| `minimize` | Minimize to tray on exit *(desktop)* |

```text
flclashm-settings: autostart,autoupdate
```

> [!IMPORTANT]
> `flclashm-settings` is applied **only if the user hasn't overridden** the provider settings manually. The user's manual choice always wins.

---

## 🔁 Behavior

| Header | Value | What it does |
|--------|-------|--------------|
| `flclashm-custom` | `add` / `update` | When to apply the customization |

- **`add`** — only when a **new** profile is added.
- **`update`** — on **every** profile refresh.
- Any other value (or absence) — no customization is applied.

---

## 📣 Standard subscription headers

Besides `flclashm-*`, the app recognizes the usual panel headers:

| Header | What it does |
|--------|--------------|
| `announce` | In-app announcement (supports a `base64:` prefix) |
| `support-url` | Support link |
| `x-hwid-max-devices-reached` | "Device limit reached" notice |
| `x-hwid-not-supported` | "HWID not supported" notice |

---

## 🚧 Boundaries

- 💡 Hints are **advisory**.
- 🔒 They **cannot** change Android protections or the security policy.
- 🏆 User settings outweigh provider recommendations.

---

> 📎 Why appearance can't affect security — in the [security policy](../development/security.md#-provider-headers).
>
> 🌍 Other languages: [Русский](../../../ru/docs/user-guide/provider-hints.md) · [中文](../../../zh/docs/user-guide/provider-hints.md) · [فارسی](../../../fa/docs/user-guide/provider-hints.md)
