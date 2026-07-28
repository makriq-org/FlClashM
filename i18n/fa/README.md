<div align="center">

<img src="../../android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="FlClashM" width="128" height="128">

# FlClashM

**عبور از سانسور در اندروید — پشت یک دکمه.**

[![دانلودها](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![آخرین نسخه](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![مجوز](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](../../LICENSE)
[![مبتنی بر FlClashX](https://img.shields.io/badge/based%20on-FlClashX-5c6bc0?style=flat-square&logo=github)](https://github.com/pluralplay/FlClashX)

کلاینت اندرویدی `mihomo`، یک fork از [FlClashX](https://github.com/pluralplay/FlClashX)، که ابزارهای پیچیدهٔ عبور از سانسور را پشت یک کلید پنهان می‌کند.

[Русский](../../README.md) · [English](../en/README.md) · [中文](../zh/README.md) · **فارسی**

</div>

---

> ⚠️ این پروژه در حال توسعهٔ فعال است. برخی قابلیت‌ها هنوز در حال بهبودند و رابط کاربری ممکن است تغییر کند.

## 📑 فهرست

- [چرا این کلاینت](#-چرا-این-کلاینت)
- [مزیت‌های کلیدی](#-مزیت‌های-کلیدی)
- [چه کارهای دیگری می‌کند](#-چه-کارهای-دیگری-میکند)
- [دانلود](#-دانلود)
- [مستندات](#-مستندات)
- [ساخت](#-ساخت)
- [قدردانی](#-قدردانی)
- [مجوز](#-مجوز)

---

## 🎯 چرا این کلاینت

چند ابزار قدرتمند برای عبور از سانسور وجود دارد، اما هرکدام در جزیرهٔ خود قرار دارند:

- 🛡 **[ByeDPI](https://github.com/hufrea/byedpi)** — عبور از DPI با دستکاری بسته‌ها برای دسترسی به منابعی که «از داخل» مسدود شده‌اند (مانند YouTube یا Discord).
- 📞 **[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — عبور از لیست‌های سفید با استتار ترافیک به‌صورت تماس WebRTC یک سرویس مجاز مانند Yandex Telemost.
- 🌩 **[StormDNS](https://github.com/nullroute1970/StormDNS)** — عبور از لیست‌های سفید با تقلید از پرس‌وجوهای معمولی DNS به یک رزالور مجاز.
- 🎭 **[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — عبور از لیست‌های سیاه با تقلید از ترافیک مرورگر Chrome.

هر فناوری برای کار خودش عالی است، اما جایی نبود که همهٔ آن‌ها را کنار هم بیاورد. می‌خواستم همه‌چیز را در یک‌جا تنظیم کنم و فقط «اتصال» را بزنم.

پس **FlClashM** را ساختم. هدفش این است که همان **یک دکمه** باشد: ارائه‌دهنده پیکربندی را آماده می‌کند، کاربر کلید را می‌زند و اتصال در هر شبکه‌ای کار می‌کند.

---

## ✨ مزیت‌های کلیدی

### 🧩 نودهای داخلی، مستقیم در پروفایل

برخلاف کلاینت‌های معمولی، FlClashM می‌تواند **نودهای ویژه را مستقیماً از پروفایل YAML اجرا کند**. آن‌ها مانند پروکسی‌های معمولی به‌نظر می‌رسند و در قوانین مسیریابی شرکت می‌کنند: یک سایت از ByeDPI، سایتی دیگر از OlcRTC و بقیه مستقیم.

<table>
<tr><td>

🛡 **ByeDPI** — پیمایش خودکار راهبردهای عبور از DPI و کش‌کردن راهبرد کارآمد.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
```

</td></tr>
<tr><td>

📞 **OlcRTC** — تونلی روی WebRTC که به‌شکل یک تماس تصویری استتار می‌شود.

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    auth:
      provider: jitsi
    room:
      id: "https://meet.example.org/room"
    crypto:
      key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    net:
      transport: datachannel
      dns: "1.1.1.1:53"
```

</td></tr>
<tr><td>

🌩 **StormDNS** — تونلی درون پرس‌وجوهای معمولی DNS.

```yaml
proxies:
  - name: "storm"
    type: stormdns
    domains: ["v.example.com"]
    encryption: chacha20
    encryption-key: "<key>"
```

</td></tr>
<tr><td>

🎭 **NaiveProxy** — تقلید از ترافیک Chrome.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

</td></tr>
</table>

📖 [دربارهٔ نودهای داخلی بیشتر بدانید ←](docs/user-guide/profiles.md)

### 🎯 تونل‌زنی جداگانه از طریق پروفایل

ارائه‌دهنده می‌تواند قوانین تونل‌زنی جداگانه را مستقیماً در پروفایل تعریف کند — کدام برنامه‌ها از VPN بروند و کدام نه. نام دقیق بسته، wildcard و عبارت باقاعده پشتیبانی می‌شود؛ فهرست‌ها را می‌توان از فایل یا URL بارگذاری کرد. پروفایل بر تنظیمات دستی اولویت دارد.

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
  exclude-package:
    - '*.yandex.*'
    - '!ru.yandex.browser'
```

📖 [دربارهٔ تونل‌زنی جداگانه بیشتر بدانید ←](docs/user-guide/split-tunneling.md)

---

## 🛠 چه کارهای دیگری می‌کند

- 🔌 **اتصال VPN/TUN** از طریق `mihomo`.
- 📥 **پروفایل‌ها** از لینک، فایل، کد QR و Android TV.
- 🔀 **حالت‌های کار**: قوانین، سراسری، مستقیم.
- 🧰 **ویجت‌ها** و **کاشی تنظیمات سریع** برای کنترل VPN.
- ⬆️ **به‌روزرسانی داخلی** با بررسی امضا و checksum.
- 🔔 **اعلان** انقضای اشتراک.
- 🚀 **اجرای خودکار** پس از راه‌اندازی مجدد دستگاه.
- 🎨 **شخصی‌سازی** از طریق [hintهای ارائه‌دهنده](docs/user-guide/provider-hints.md).

---

## 📥 دانلود

بیلدهای منتشرشده در [GitHub Releases](https://github.com/makriq-org/FlClashM/releases) قرار دارند.

| فایل | برای چه |
|------|---------|
| `FlClashM-android-universal.apk` | بیلد همگانی (اگر مطمئن نیستید، همین) |
| `FlClashM-android-arm64-v8a.apk` | ARM ۶۴بیتی (بیشتر گوشی‌های امروزی) |
| `FlClashM-android-armeabi-v7a.apk` | ARM ۳۲بیتی (دستگاه‌های قدیمی) |
| `FlClashM-android-x86_64.apk` | x86_64 (شبیه‌سازها، برخی تبلت‌ها) |
| `FlClashM-android-release.aab` | Android App Bundle |

> ℹ️ به‌روزرسان داخلی به‌طور پیش‌فرض فقط نسخه‌های پایدار را نشان می‌دهد. نسخه‌های پیش‌انتشار را می‌توان در تنظیمات فعال کرد.

---

## 📚 مستندات

مرجع کامل — در **[مرکز مستندات](docs/README.md)**.

**🚀 برای کاربران**
- 🧩 [نودهای داخلی](docs/user-guide/profiles.md) — ByeDPI، OlcRTC، StormDNS، NaiveProxy
- 🎯 [تونل‌زنی جداگانه](docs/user-guide/split-tunneling.md) — مدیریت از طریق پروفایل
- 🎨 [hintهای ارائه‌دهنده](docs/user-guide/provider-hints.md) — ظاهر و رفتار

**🛠 برای توسعه‌دهندگان**
- 🏗 [معماری](docs/development/architecture.md) · ⚙️ [محیط اجرا](docs/development/runtime.md) · 🔒 [امنیت](docs/development/security.md)
- 📦 [انتشار](docs/development/release-contract.md) · 🔄 [همگام‌سازی با FlClashX](docs/development/upstream-sync.md) · ✅ [بررسی بیلد](docs/development/verification.md)

---

## 🏗 ساخت

نیازمند **Flutter 3.41.x**، **JDK 17**، **Android SDK/NDK** و **Go 1.26.x**.

### روی NixOS (توصیه‌شده)

همهٔ وابستگی‌ها و نسخه‌هایشان را `flake.nix` تثبیت می‌کند. بستهٔ دیباگ arm64 با یک فرمان ساخته می‌شود:

```bash
nix develop -c make dev
```

نتیجه: `build/app/outputs/flutter-apk/app-debug.apk`.

سایر کارها هم به همین شکل:

```bash
nix develop -c make fetch-upstream check
nix develop -c make install-dev
nix develop -c make release
nix develop -c make clean
```

> هدف‌های `test`، `analyze`، `boundaries`، `release-contract` و `drift` نیز در دسترس‌اند.

### بدون Nix

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

📖 جزئیات بیشتر در [بررسی بیلد](docs/development/verification.md).

---

## 🙏 قدردانی

FlClashM بر پایهٔ [FlClashX](https://github.com/pluralplay/FlClashX) ساخته شده — یک کلاینت چندسکویی عالی برای Clash/Mihomo. سپاس فراوان از نویسندگان برای کار و کد متن‌بازشان که بدون آن این پروژه ممکن نبود.

سپاس ویژه از نویسندگان [ByeDPI](https://github.com/hufrea/byedpi)، [OlcRTC](https://github.com/openlibrecommunity/olcrtc)، [StormDNS](https://github.com/nullroute1970/StormDNS) و [NaiveProxy](https://github.com/klzgrad/naiveproxy) — که بدون ابزارهایشان عبور از سانسور ممکن نبود.

---

## 📄 مجوز

کد برنامه تحت مجوز **GPL-3.0** منتشر می‌شود. هسته‌های شخص‌ثالث و فایل‌های اجرایی همراه، مجوزهای اصلی خود را حفظ می‌کنند.
