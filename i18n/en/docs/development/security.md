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
- 🧱 In `olcrtc profiles[]`, `socks.host`, `socks.port`, and `crypto.key_file` are recursively forbidden; the rest is passed to OlcRTC transparently.
- 🛡 `byedpi` only checks the specified URLs.

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
