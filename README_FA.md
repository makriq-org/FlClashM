# FlClashM

[![Загрузки](https://img.shields.io/github/downloads/makriq-org/FlClashM/total?style=flat-square&logo=github)](https://github.com/makriq-org/FlClashM/releases/)
[![Последняя версия](https://img.shields.io/github/release/makriq-org/FlClashM/all.svg?style=flat-square)](https://github.com/makriq-org/FlClashM/releases/)
[![Лицензия](https://img.shields.io/github/license/makriq-org/FlClashM?style=flat-square)](LICENSE)
[![Based on FlClashX](https://img.shields.io/badge/based%20on-FlClashX-5c6bc0?style=flat-square&logo=github)](https://github.com/pluralplay/FlClashX)

> کلاینت اندروید برای `mihomo`، شاخه‌ای از [FlClashX](https://github.com/pluralplay/FlClashX)، که ابزارهای پیچیده دور زدن فیلترینگ را پشت یک دکمه پنهان می‌کند.

[English version](README_EN.md) | [中文版](README_ZH.md) | [Русская версия](README.md) | [نسخه فارسی](README_FA.md)

---

## چرا این کلاینت

چندین ابزار قدرتمند برای دور زدن فیلترینگ وجود دارد:

- **[ByeDPI](https://github.com/hufrea/byedpi)** — دور زدن DPI برای دسترسی به منابعی که «از داخل» مسدود شده‌اند (مثل یوتیوب یا دیسکورد).
- **[OlcRTC](https://github.com/openlibrecommunity/olcrtc)** — دور زدن لیست سفید با جعل تماس‌های WebRTC سرویس‌های مجاز.
- **[NaiveProxy](https://github.com/klzgrad/naiveproxy)** — دور زدن لیست سیاه با جعل ترافیک مرورگر کروم.

هر فناوری برای کار خاصی مناسب است و جایی وجود نداشت که همه این راه‌حل‌ها را یکجا جمع کند. می‌خواستم همه چیز را یکجا تنظیم کنم و فقط دکمه «اتصال» را بزنم.

بنابراین **FlClashM** را ساختم. هدف این پروژه تبدیل شدن به همان **یک دکمه** است: ارائه‌دهنده پیکربندی را آماده می‌کند، کاربر کلید را می‌زند و اتصال در هر شبکه‌ای کار می‌کند.

> ⚠️ این پروژه در حال توسعه فعال است. برخی ویژگی‌ها هنوز در حال تکمیل هستند و رابط کاربری ممکن است تغییر کند.

---

## مزایای اصلی

### نودهای داخلی مستقیم در پروفایل

برخلاف کلاینت‌های معمولی، FlClashM می‌تواند **نودهای ویژه را مستقیماً از پروفایل YAML** اجرا کند. آن‌ها مثل پروکسی‌های معمولی ظاهر می‌شوند و در قوانین مسیریابی شرکت می‌کنند: یک سایت را می‌توان از طریق ByeDPI فرستاد، دیگری را از طریق OlcRTC و بقیه را مستقیم.

مثال برای [ByeDPI](https://github.com/hufrea/byedpi). FlClashM به‌طور خودکار استراتژی‌ها را از لیست ByeByeDPI بررسی و نسخه کارآمد را کش می‌کند.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    mode: auto
    strategy-list: byebyeedpi
    test:
      urls:
        - "https://example.com/"
```

مثال برای [OlcRTC](https://github.com/openlibrecommunity/olcrtc).

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    auth:
      provider: jitsi
    room:
      id: "https://meet.example.org/room"
    crypto:
      key: "0123456789abcdef..."
```

مثال برای [NaiveProxy](https://github.com/klzgrad/naiveproxy).

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    proxy: "https://user:pass@example.com"
```

[جزئیات بیشتر درباره نودهای داخلی](docs/user-guide/profiles.md)

## تونل‌زنی جداگانه از طریق پروفایل

ارائه‌دهنده می‌تواند قوانین تونل‌زنی جداگانه را مستقیماً در پروفایل تنظیم کند — کدام برنامه‌ها باید از VPN عبور کنند و کدام نه. نام دقیق پکیج، الگوها و عبارات منظم پشتیبانی می‌شوند.

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

می‌توان لیست‌ها را از فایل‌ها یا URL بارگذاری کرد. پروفایل بر تنظیمات دستی اولویت دارد.

[جزئیات بیشتر درباره تونل‌زنی جداگانه](docs/user-guide/split-tunneling.md)

---

## ویژگی‌های دیگر

- **اتصال VPN/TUN** از طریق `mihomo`.
- **پروفایل‌ها** از طریق لینک، فایل، کد QR و Android TV.
- **حالت‌های کار**: قوانین، جهانی، اتصال مستقیم.
- **ویجت‌ها** و **کاشی تنظیمات سریع** برای مدیریت VPN.
- **به‌روزرسانی داخلی** با بررسی checksum.
- **اعلان‌ها** درباره انقضای اشتراک.
- **اجرای خودکار** پس از ریستارت دستگاه.
- **پوسته** از طریق hintهای ارائه‌دهنده (هدرها).

---

## دانلود

بیلدهای آماده در [GitHub Releases](https://github.com/makriq-org/FlClashM/releases) منتشر می‌شوند.

| فایل | توضیحات |
|------|----------|
| `FlClashM-android-universal.apk` | بیلد جهانی |
| `FlClashM-android-arm64-v8a.apk` | ARM شصت و چهار بیتی |
| `FlClashM-android-armeabi-v7a.apk` | ARM سی و دو بیتی |
| `FlClashM-android-x86_64.apk` | x86_64 |
| `FlClashM-android-release.aab` | Android App Bundle |

به‌طور پیش‌فرض، بارگذار داخلی فقط نسخه‌های پایدار را نشان می‌دهد. بیلدهای آزمایشی را می‌توان در تنظیمات فعال کرد.

---

## مستندات

### برای کاربران
- **[نودهای داخلی](docs/user-guide/profiles.md)** — ByeDPI, OlcRTC, NaiveProxy
- **[تونل‌زنی جداگانه](docs/user-guide/split-tunneling.md)** — مدیریت از طریق پروفایل
- **[Hintهای ارائه‌دهنده](docs/user-guide/provider-hints.md)** — پوسته و رفتار

### برای توسعه‌دهندگان
- **[معماری](docs/development/architecture.md)** — لایه‌ها و سرویس‌ها
- **[محیط اجرا](docs/development/runtime.md)** — پردازش پروفایل و نودهای داخلی
- **[امنیت](docs/development/security.md)** — سیاست امنیتی
- **[انتشار](docs/development/release-contract.md)** — انتشار و بازگشت نسخه‌ها
- **[همگام‌سازی با FlClashX](docs/development/upstream-sync.md)** — به‌روزرسانی پایه
- **[بررسی بیلد](docs/development/verification.md)** — بررسی‌های محلی و CI

---

## ساخت

به Flutter 3.41.x، JDK 17، Android SDK/NDK و Go 1.26.x نیاز دارید.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter test test/product
flutter build apk --debug
```

---

## قدردانی

FlClashM بر پایه [FlClashX](https://github.com/pluralplay/FlClashX) ساخته شده است — یک کلاینت عالی کراس‌پلتفرم برای Clash/Mihomo. از نویسندگان آن برای کار انجام‌شده و کد بازشان بسیار سپاسگزاریم که بدون آن‌ها این پروژه ممکن نبود.

قدردانی ویژه از نویسندگان [ByeDPI](https://github.com/hufrea/byedpi)، [OlcRTC](https://github.com/openlibrecommunity/olcrtc) و [NaiveProxy](https://github.com/klzgrad/naiveproxy) — بدون تلاش آن‌ها دور زدن فیلترینگ ممکن نبود.

---

## مجوز

کد اپلیکیشن تحت مجوز GPL-3.0 منتشر می‌شود. هسته‌های شخص ثالث و فایل‌های اجرایی داخلی مجوزهای اصلی خود را حفظ می‌کنند.
