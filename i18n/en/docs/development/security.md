# 🔒 Security Policy

The fork's key invariant: **appearance and provider hints cannot weaken runtime protections.**

## 🛡 Runtime policy

`SecurityPolicy` forces TUN on Android. This layer doesn't change any other profile or runtime-config parameters.

## 📱 Android protections

- 🔌 TUN is forced on.
- 🎯 Split tunneling from the profile takes priority.
- 📸 The applied-package-rules indicator reads a **snapshot of the Android VPN service**, not the current core config (see [the VPN snapshot](runtime.md#-android-vpn-applied-options-snapshot)).
- ✍️ The app update manifest is verified with a built-in **Ed25519** public key before its contents are parsed.
- 🔐 The update downloader verifies the APK **SHA-256** from the signed manifest and only iterates over the mirrors listed in it.
- 🧾 The APK signature is additionally verified by the Android installer against the signature of the already-installed app.
- 🚫 Built-in nodes can't set local addresses and ports.
- 📞 `olcrtc` works only in CNC mode.
- 🧱 OlcRTC rejects `profiles`, `failover`, `video.hw`, local listeners, and file-backed keys.
- 🛡 `byedpi` only checks the specified URLs.
- 🔗 Remote ByeDPI strategies use the same bounded public-HTTPS and stale-cache policy as StormDNS lists.
- 🌩 `stormdns` additionally rejects SOCKS5 authentication, the `local-dns-*` block, the log directory, `config-version`, and the interactive `startup.mode: ask`.

## 🌩 StormDNS

⚠️ `encryption: none` and `xor` are allowed per the upstream contract: they **do not hide payload contents** from the resolver operator.

`resolvers` is the only case where a profile hands a node a list of network addresses, so the sources are validated separately:

- ✅ Allowed sources in `resolvers`: `system`, an IP, `IP:port`, a CIDR range, and an `https://` link to a list.
- 🔗 A list link is accepted **over HTTPS only**, with no userinfo or fragment, no `localhost` and no local addresses; the response is capped at **1 MiB** and **15 s**.
- 🚫 The fetch does not go through a proxy, does not follow redirects, accepts only a `200` response, and connects only to an already-validated public address.
- 💾 The remote-list cache is kept per link. When a source is unreachable, the last copy is used — even after `refresh` expires; without a copy the link is simply skipped instead of failing the profile apply.
- 🧮 CIDR expansion is capped at 65536 addresses: on wide ranges upstream iterates all of them, which would hang the app.
- 🔁 The final list is deduplicated by IP — the first occurrence wins, along with its port.

## 🌐 Connectivity-check addresses

For `connectivity-check` and `strategy-test`, **only** HTTP(S) addresses without credentials or local destinations are allowed.

- 🚫 Loopback, private, link-local, multicast, and reserved ranges, as well as local names, are forbidden.
- 🔁 Before the network request, the DNS result is re-verified.
- 🔗 A connection to the destination is established only via the SOCKS command through the node being verified.

## 🎨 Provider headers

- 💡 `flclashm-*` headers stay **advisory** (see [provider hints](../user-guide/provider-hints.md)).
- 🔒 Appearance **cannot** change runtime protections.

---

> 🌍 Other languages: [Русский](../../../ru/docs/development/security.md) · [中文](../../../zh/docs/development/security.md) · [فارسی](../../../fa/docs/development/security.md)
