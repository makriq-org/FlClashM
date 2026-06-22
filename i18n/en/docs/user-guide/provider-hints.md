# Provider hints

The provider can pass hints with the `flclashm-*` prefix in subscription headers. They affect the app's appearance and behavior, but cannot weaken security.

## How it works

The subscription returns the YAML profile in the response body, and hints in the headers. FlClashM applies them when adding or updating a profile.

## Available headers

### Appearance

| Header | Description |
|--------|-------------|
| `flclashm-background` | Background image |
| `flclashm-hex` | Color scheme |

### Home screen

| Header | Description |
|--------|-------------|
| `flclashm-widgets` | Widget order |
| `flclashm-view` | Nodes page view |
| `flclashm-denywidgets` | Disable home screen editing |

### Service info

| Header | Description |
|--------|-------------|
| `flclashm-servicename` | Service name |
| `flclashm-servicelogo` | Service logo |
| `flclashm-serverinfo` | Server information |

### Settings

| Header | Description |
|--------|-------------|
| `flclashm-settings` | Auto-start and update check |
| `flclashm-globalmode` | Mode selection visibility |

### Behavior

| Header | Description |
|--------|-------------|
| `flclashm-custom` | When to apply appearance: `add` or `update` |

## Boundaries

- Hints are advisory.
- They cannot modify Android security or the security policy.
- User settings take priority over provider recommendations.
