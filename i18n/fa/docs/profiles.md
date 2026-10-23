<div dir="rtl">

# 🧩 تنظیم پروفایل

[← README](../README.md) · [Русский](../../ru/docs/profiles.md) · [English](../../en/docs/profiles.md) · [中文](../../zh/docs/profiles.md) · **فارسی**

برای استفاده از تنظیمات آماده، اشتراک را در برنامه وارد کنید. این راهنما برای ویرایش YAML یا آماده‌کردن اشتراک برای دیگران است.

[نودها](#nodes) · [نود ذخیره](#activation) · [بررسی](#checks) · [برنامه‌ها](#apps) · [هدرهای اشتراک](#headers)

## 🚀 پروفایل ساده

<div dir="ltr">

```yaml
proxies:
  - name: dpi-auto
    type: byedpi
proxy-groups:
  - name: main
    type: select
    proxies: [dpi-auto, DIRECT]
rules:
  - MATCH,main
```

</div>

نودهای داخلی در `proxies` قرار می‌گیرند و با گروه‌ها و قوانین معمول mihomo کار می‌کنند. برنامه آدرس‌ها، پورت‌ها و فایل‌های محلی را تعیین می‌کند. `server` و `port` راه دور NaiveProxy در پروفایل مشخص می‌شوند.

<a id="nodes"></a>

## 🔌 نودهای داخلی

فقط ByeDPI از UDP پشتیبانی می‌کند؛ به‌طور پیش‌فرض فعال است و با `udp: false` خاموش می‌شود. NaiveProxy، OlcRTC و StormDNS از UDP پشتیبانی نمی‌کنند.

### NaiveProxy

<div dir="ltr">

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

</div>

فیلدهای الزامی: `name`، `type`، `server`، `port`، `username`، `password`. مقدار پیش‌فرض `transport` برابر `https` است؛ `quic` هم مجاز است. اختیاری: `insecure-concurrency` (1–4)، `tunnel-timeout`، `idle-timeout`، `post-quantum`، `headers`، `host-resolver-rules`. فیلد قدیمی `proxy`، مقدار محلی `listen`، فایل‌های تشخیصی، زنجیره‌ها و فیلدهای ناشناخته رد می‌شوند.

### ByeDPI

<div dir="ltr">

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    strategies:
      - builtin:byebyeedpi
      - "--disorder 1"
      - "https://example.org/byedpi-strategies.txt"
```

</div>

در `mode: auto` راهبردها آزمایش و نتیجهٔ کارآمد برای هر شبکهٔ فیزیکی جداگانه ذخیره می‌شود (تا ۱۶ شبکه، بدون دسترسی به SSID). با پایان مهلت راه‌اندازی، راهبرد موقت استفاده و انتخاب در پس‌زمینه ادامه می‌یابد. نتیجهٔ تأییدشده و راهبرد موقت جدا ذخیره می‌شوند. `mode: manual` از `strategy` استفاده می‌کند؛ بدون `mode`، وجود `strategy` حالت manual و نبود آن حالت auto را انتخاب می‌کند.

<div dir="ltr">

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    strategy: "--disorder 1 --auto=torst --tlsrec 1+s"
```

</div>

فهرست HTTPS در هر خط یک راهبرد دارد؛ خطوط خالی و خطوط شروع‌شده با `#` نادیده گرفته می‌شوند. `{sni}` پشتیبانی می‌شود. محدودیت دانلود مانند فهرست حل‌کننده‌های پایین است. `strategy-test` فقط برای انتخاب راهبرد است و جای `connectivity-check` را نمی‌گیرد؛ فیلد قدیمی `test` پشتیبانی نمی‌شود.

<details>
<summary>پارامترهای انتخاب خودکار</summary>

| پارامتر | پیش‌فرض | توضیح |
|---------|---------|-------|
| `strategies` | `[builtin:byebyeedpi]` | ترکیب مرتب فهرست داخلی، راهبردهای inline و فهرست عمومی HTTPS |
| `strategy-test.urls` | endpoint داخلی YouTube | آدرس‌های انتخاب |
| `strategy-test.sni` | — | نام میزبان برای جای‌گذاری `{sni}` |
| `strategy-test.dns-resolver` | `https://1.1.1.1/dns-query` | حل‌کننده DoH برای نشانی آزمایش (دور زدن fake-ip)؛ `system` از حل‌کننده سیستم استفاده می‌کند |
| `strategy-test.timeout` | `5s` | مهلت هر بررسی |
| `strategy-test.requests` | `1` | درخواست به‌ازای هر راهبرد |
| `strategy-test.request-concurrency` | `4` | درخواست‌های HTTP موازی درون یک نامزد |
| `strategy-test.min-success-ratio` | `1.0` | کمترین نسبت درخواست‌های موفق |
| `strategy-selection.strategy-concurrency` | `4` | راهبردهای هم‌زمان بررسی‌شونده |
| `strategy-selection.startup-timeout` | `15s` | بودجهٔ انتخاب پیش از شروع نود |
| `strategy-selection.continue-in-background` | `true` | ادامهٔ فهرست در پس‌زمینه پس از fallback |
| `strategy-selection.fallback-strategy` | — | آرگومان راهبرد موقت اگر foreground به‌موقع تمام نشد |
| `strategy-selection.cache.ttl` | `7d` | عمر کش |
| `strategy-selection.cache.recheck-after` | `1d` | فاصلهٔ بررسی مجدد |
| `strategy-selection.retry-after` | `5m` | مکث پیش از انتخاب تازه پس از fallback |
| `strategy-selection.cache.failure-threshold` | `2` | تعداد خطا تا بازنشانی کش |

</details>

### OlcRTC

<div dir="ltr">

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    provider: jitsi
    room: "https://meet.example.org/room"
    encryption-key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    transport: datachannel
    dns-server: "1.1.1.1:53"
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "rtc"]
```

</div>

فقط حالت کلاینت CNC مجاز است. کلید دقیقاً ۶۴ نویسهٔ hexadecimal است. `provider: none` به `engine`، `engine-url`، `engine-token` نیاز دارد؛ برای سایر ارائه‌دهندگان این فیلدها ممنوع‌اند. `profiles`، `failover`، `video.hw`، listener محلی و کلید از فایل مجاز نیستند.

`dns-server: system` از نخستین DNS شبکهٔ فیزیکی Android استفاده می‌کند و با تغییر آن نود فعال را به‌روز می‌کند. بدون DNS سیستم، راه‌اندازی تا به‌روزرسانی شبکه منتظر می‌ماند. کلاینت و سرور باید از OLC2 و OLVC 5 پشتیبانی کنند.

<details>
<summary>فیلدها و انتقال OlcRTC</summary>

| پارامتر | توضیح |
|---------|-------|
| `provider` | ارائه‌دهندهٔ اتصال: `jitsi`، `telemost`، `wbstream`، `none` |
| `room` | شناسهٔ اتاق تماس تصویری |
| `encryption-key` | کلید رمزنگاری ۲۵۶بیتی — **دقیقاً ۶۴ کاراکتر هگز** |
| `transport` | ترابری: `datachannel`، `vp8channel`، `seichannel`، `videochannel` |
| `dns-server` | سرور DNS الزامی به‌شکل `آدرس:پورت` |
| `transport-options` | گزینه‌های اختیاری transport انتخاب‌شده؛ برای `datachannel` ممنوع است |

برای `datachannel`، بخش `transport-options` ممنوع است. پیش‌فرض `vp8channel`: مقدار `fps: 30` و `batch-size: 64`؛ برای `seichannel` همچنین `fragment-size: 900` و `ack-timeout: 2s`. در `videochannel`: فیلدهای `codec` (`qrcode`/`tile`)، `width`، `height`، `fps`، `fragment-size`، `qr-recovery`، `tile-module`، `tile-rs`. پیش‌فرض: `qrcode`، اندازهٔ 1920×1080 و `qr-recovery: low`؛ برای tile اندازهٔ 1080×1080 است. `bitrate` قدیمی پذیرفته اما نادیده گرفته می‌شود.

<div dir="ltr">

```yaml
transport: seichannel
transport-options:
  fps: 30
  batch-size: 64
  fragment-size: 900
  ack-timeout: 2s
```

</div>

</details>

### StormDNS

<div dir="ltr">

```yaml
proxies:
  - name: "storm"
    type: stormdns
    domains: ["v.example.com"]
    encryption: chacha20
    encryption-key: "<key>"
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "storm"]
```

</div>

`domains`، `encryption`، `encryption-key` الزامی‌اند، پیش‌فرض ندارند و باید با سرور یکسان باشند. `none` و `xor` محتوا را از گردانندهٔ حل‌کننده پنهان نمی‌کنند. نخستین راه‌اندازی حل‌کننده‌ها را اسکن می‌کند و ممکن است تا دو دقیقه طول بکشد.

<details>
<summary>حل‌کننده‌ها و حافظهٔ نهان</summary>

| فیلد | توضیح |
|------|-------|
| `domains` | دامنه‌های واگذارشده به سرور StormDNS |
| `encryption` | `none`، `xor`، `chacha20`، `aes-128-gcm`، `aes-192-gcm`، `aes-256-gcm` |
| `encryption-key` | کلید مشترک؛ باید با سرور یکی باشد |

مقدار خالی یا نبود `resolvers` به‌معنی `[system]` است. منابع به‌ترتیب باز می‌شوند؛ موارد تکراری بر اساس IP حذف و اولین پورت نگه داشته می‌شود. نتیجهٔ خالی رد می‌شود. CIDR پروفایل حداکثر 65536 آدرس دارد.

| مورد | چه اضافه می‌کند |
|------|-----------------|
| `system` | DNS شبکهٔ فیزیکی (نه VPN) |
| `8.8.8.8` | یک resolver روی پورت ۵۳ |
| `1.1.1.1:5353` | یک resolver با پورت اختصاصی |
| `192.168.1.0/30` | CIDR: در IPv4 نشانی شبکه و broadcast برداشته نمی‌شوند؛ بازهٔ بزرگ‌تر از ۶۵۵۳۶ نشانی رد می‌شود |
| `https://…` | resolverها از یک فهرست راه دور |

هر پروفایل حداکثر ۳۲ فهرست HTTPS دارد؛ آدرس دانلود نباید اعتبارنامه، fragment یا آدرس سرور محلی داشته باشد؛ IP/CIDR خصوصی داخل فهرست مجاز است. محدودیت پاسخ: 1 MiB و ۱۵ ثانیه؛ تغییرمسیر ممنوع است. در خطا حتی پس از `refresh` از کش قبلی استفاده می‌شود؛ بدون کش، منبع رد می‌شود. `refresh` هنگام اعمال پروفایل بررسی می‌شود.

| `resolver-policy` | پیش‌فرض | توضیح |
|-------------------|---------|-------|
| `refresh` | `24h` | فاصلهٔ به‌روزرسانی فهرست‌های راه دور |
| `strategy` | `least-loss` | `random`، `round-robin`، `least-loss`، `lowest-latency` |
| `auto-disable` | `true` | غیرفعال‌کردن resolverهایی که پاسخ نمی‌دهند |
| `recheck` | `true` | آزمایش دوره‌ای resolverهای غیرفعال |

| `startup.mode` | چه می‌کند |
|----------------|-----------|
| `scan` | پویش کامل resolverها (کندترین شروع) |
| `cached` (پیش‌فرض) | شروع از کش بدون بررسی دوبارهٔ MTU |
| `verified` | شروع از کش با بررسی دوبارهٔ MTU |

کش به حل‌کننده‌ها، `domains` و نسخهٔ StormDNS وابسته است. `startup.max-age` تعداد صحیح روز با پیش‌فرض `30d` است. بدون کش مناسب، اسکن دوباره انجام می‌شود. تغییر DNS سیستم کش MTU را پاک و نودهای فعال وابسته را بدون UI راه‌اندازی مجدد می‌کند. DNS/SOCKS محلی، فایل حل‌کننده، مسیر لاگ و `startup.mode: ask` در پروفایل ممنوع‌اند.

</details>

<details>
<summary>پیش‌تنظیم‌ها و تنظیم دقیق</summary>

ترتیب: مقادیر پیش‌فرض → `preset` → فیلدهای صریح. مدت‌ها رشتهٔ دارای واحد هستند (`600ms`، `30s`، `24h`، `30d`). مقادیر خارج از محدوده پیش از اجرا رد می‌شوند.

| `preset` | تکرار (upload / download / upload-setup / download-setup) | فشرده‌سازی |
|----------|-------------------------------------------------------------|------------|
| `messenger` (پیش‌فرض) | ۱ / ۷ / ۳ / ۸ | `lz4` |
| `balanced` | ۲ / ۵ / ۳ / ۶ | `lz4` |
| `bulk` | ۳ / ۳ / ۴ / ۴ | `zstd` |

<div dir="ltr">

```yaml
preset: bulk
duplication:
  upload: 2
compression:
  upload: zlib
```

</div>

| بلوک | فیلدها و مرزها |
|------|----------------|
| `duplication` | `upload`، `download`، `upload-setup`، `download-setup` — ۱ تا ۸ |
| `compression` | `upload`، `download` — `none`، `zstd`، `lz4`، `zlib`؛ `min-size` — ۱۰۰ تا ۶۵۵۳۵ |
| `mtu.upload`، `mtu.download` | `min` — ۱ تا ۶۵۵۳۵؛ `max` — ۰ تا ۶۵۵۳۵ که در آن `0` سقف را برمی‌دارد |
| `arq` | `window` ۱ تا ۶۰۰۰، `nack-max-gap` ۰ تا ۱۵۰۰، `max-control-retries` ۵ تا ۵۰۰۰، `max-data-retries` ۶۰ تا ۱۰۰۰۰۰؛ بقیه مدت‌زمان‌اند |
| `ping` | فقط مدت‌زمان: بازه‌های `aggressive`/`lazy`/`cooldown`/`cold` و آستانه‌های `warm`/`cool`/`cold` |
| `runtime` | `workers` و `process-workers` ۱ تا ۶۴، اندازهٔ صف‌ها و استخرها، مدت‌زمان تلاش مجدد؛ `base-encode` پرچم است |

محدودیت‌های وابسته به‌طور کامل بررسی می‌شوند:

- `duplication.upload-setup` ≥ `upload`، `download-setup` ≥ `download`
- `mtu.<جهت>.max` ≥ `min`
- `arq.initial-rto` ≤ `max-rto`، `arq.control-initial-rto` ≤ `control-max-rto`
- `arq.nack-max-gap` ≤ `arq.window / 4`
- `ping.aggressive-interval` ≤ `lazy-interval` ≤ `cooldown-interval` ≤ `cold-interval`
- `ping.warm-threshold` ≤ `cool-threshold` ≤ `cold-threshold`
- `runtime.process-workers` ≥ `runtime.workers`
- `runtime.session-retry-base` ≤ `session-retry-max`

نام فیلدها با پیکربندی StormDNS یکی است.

</details>

<a id="activation"></a>

## 😴 نود ذخیرهٔ خوابیده

پیش‌فرض OlcRTC و StormDNS برابر `activation: auto` است: با انتخاب دستی یا خرابی گروه تحت نظر اجرا می‌شوند. نود باید عضو مستقیم گروه باشد. بدون انتخاب یا اتصال، پس از `sleep.idle` می‌خوابد؛ `0s` خواب را تا راه‌اندازی مجدد VPN غیرفعال می‌کند. برای اجرا همراه پروفایل از `activation: always` استفاده کنید.

<div dir="ltr">

```yaml
activation:
  mode: auto
  wake:
    urls: ["https://example.org/generate_204"]
    interval: 30s
    failures: 2
    retry-after: 5m
  sleep:
    idle: 15m
```

</div>

<details>
<summary>پارامترهای بیداری و خواب</summary>

| پارامتر | پیش‌فرض | توضیح |
|---------|---------|-------|
| `mode` | `auto` | `auto` پشتیبان را می‌خواباند؛ `always` راه‌اندازی همیشگی قدیمی |
| `wake.urls` | زنجیرهٔ `connectivity-check` | آدرس‌های HTTP(S) عمومی برای وارسی گروه زیرنظر |
| `wake.interval` | `30s` | فاصلهٔ وارسی هنگام خواب |
| `wake.failures` | `2` | دورهای ناموفق پیاپی تا بیدارشدن |
| `wake.retry-after` | `5m` | مکث پس از راه‌اندازی ناموفق |
| `sleep.idle` | `15m` | مدت بدون اتصال و انتخاب تا خواب؛ `0s` یعنی تا راه‌اندازی مجدد VPN نخوابد |

</details>

<a id="checks"></a>

## 🩺 بررسی دسترسی

فرایند و پورت SOCKS همیشه بررسی می‌شوند. آدرس HTTP(S) از `connectivity-check.urls` نود، نزدیک‌ترین گروه یا آدرس تست عمومی برنامه گرفته می‌شود. `required: false` بررسی را در پس‌زمینه انجام می‌دهد؛ `true` به آدرس نیاز دارد و در شکست، راه‌اندازی را بازمی‌گرداند. هر پاسخ معتبر HTTP از جمله 4xx/5xx موفق است.

<div dir="ltr">

```yaml
connectivity-check:
  urls: ["https://example.org/generate_204"]
  required: true
```

</div>

فقط URL عمومی HTTP(S) بدون اعتبارنامه یا fragment مجاز است. DNS پیش از درخواست بررسی می‌شود؛ ترافیک از SOCKS نود آزمایشی عبور می‌کند و مسیر مستقیم جایگزین ندارد. TLS نام اصلی میزبان را تأیید می‌کند.

<details>
<summary>همهٔ پارامترهای بررسی</summary>

| فیلد | پیش‌فرض | چه تعیین می‌کند |
|------|---------|-----------------|
| `urls` | — | آدرس‌های بررسی (HTTP(S) عمومی، بدون اعتبارنامه یا fragment) |
| `required` | `false` | آیا بررسی برای راه‌اندازی الزامی است |
| `timeout` | `5s` | مهلت هر درخواست |
| `startup-timeout` | `30s` (برای `stormdns`: `2m`) | بودجهٔ کل بررسی در راه‌اندازی |
| `retry-interval` | `1s` | مکث بین تلاش‌ها |
| `requests` | `1` | چند درخواست |
| `concurrency` | `1` | چند درخواست هم‌زمان |
| `min-success-ratio` | — | کمترین نسبت پاسخ‌های موفق (بدون آن، یک موفقیت کافی است) |

</details>

<a id="apps"></a>

## 🎯 کدام برنامه‌ها از VPN استفاده می‌کنند

قوانین پروفایل بر تنظیم دستی اولویت دارند. `include-package` فقط برنامه‌های فهرست‌شده و `exclude-package` سایر برنامه‌ها را از VPN عبور می‌دهد. استفادهٔ هم‌زمان ممنوع است؛ فهرست خالی صریح با نبود قانون فرق دارد.

<div dir="ltr">

```yaml
tun:
  enable: true
  include-package:
    - org.telegram.messenger
    - com.termux
```

</div>

<div dir="ltr">

```yaml
tun:
  enable: true
  exclude-package:
    - com.android.chrome
    - org.mozilla.firefox
```

</div>

| قالب | نمونه | معنی |
|------|-------|------|
| 🎯 نام دقیق | `com.termux` | تطبیق دقیق بسته |
| ✳️ wildcard | `*.yandex.*` | همهٔ برنامه‌های Yandex |
| 🔤 regex | `re:^org\.mozilla\..+$` | همهٔ برنامه‌های Mozilla |
| 🚫 استثنا | `!ru.yandex.browser` | حذف از فهرست |

`include-package-url` / `exclude-package-url` فهرست HTTP(S) می‌پذیرند: هر خط یک بسته یا انتخابگر. کش قبلی بدون شبکه کار می‌کند؛ اشتراک‌ها و فهرست برنامه‌ها می‌توانند روی سرور خصوصی باشند. فایل‌های محلی `include-package-file` / `exclude-package-file` در Android نادیده گرفته و ثبت می‌شوند.

<div dir="ltr">

```yaml
tun:
  enable: true
  include-package-url: https://example.com/packages.txt
```

</div>

هنگام اجرای VPN، رابط قوانین آخرین ایجاد موفق تونل را نشان می‌دهد. بارگذاری مجدد mihomo به‌تنهایی آن‌ها را تغییر نمی‌دهد. اگر عکس فوری در دسترس نباشد، رابط صریحاً تعریف پروفایل را به‌جای وضعیت تأییدشده نشان می‌دهد.

<a id="headers"></a>

## 🎨 هدرهای اشتراک

پاسخ HTTP اشتراک شامل YAML در بدنه و راهنماها در هدر است. `flclashm-*` و `flclashx-*` سازگار پذیرفته می‌شوند؛ اولی اولویت دارد. مقادیر بولی `true`/`false` هستند.

<div dir="ltr">

```text
flclashm-custom: update
flclashm-hex: 5c6bc0:vibrant:pureblack
flclashm-view: type:tab;sort:delay;card:min
flclashm-settings: autostart,autoupdate
```

</div>

`flclashm-custom: add` ظاهر را هنگام افزودن و `update` در هر به‌روزرسانی اعمال می‌کند؛ در غیر این صورت ظاهر اعمال نمی‌شود. تنظیم دستی بر `flclashm-settings` اولویت دارد. `androidsecure` فقط mixed-port را می‌بندد و انتخاب VPN را حفظ می‌کند. گروه `GLOBAL` از `flclashm-override` / `flclashx-override` پشتیبانی می‌کند و اولی اولویت دارد.

<details>
<summary>مرجع هدرها و قالب‌ها</summary>

| هدر | مقدار | کاربرد |
|---|---|---|
| `flclashm-background` | `URL` | تصویر پس‌زمینه |
| `flclashm-hex` | `HEX[:variant][:pureblack]` | رنگ‌بندی |
| `flclashm-widgets` | `list` | ترتیب ابزارک‌ها |
| `flclashm-view` | `key:value;…` | چیدمان صفحهٔ نودها |
| `flclashm-newboard` | `true/false` | داشبورد جدید |
| `flclashm-denywidgets` | `true/false` | منع ویرایش داشبورد |
| `flclashm-servicename` | `base64` | نام سرویس |
| `flclashm-servicelogo` | `base64(URL)` | نشان سرویس |
| `flclashm-serverinfo` | `base64` | نام گروه اطلاعات سرور |
| `flclashm-buyplan` | `URL` | تمدید اشتراک |
| `flclashm-buytraffic` | `URL` | خرید ترافیک |
| `flclashm-settings` | `autostart,autoupdate,…` | تنظیمات جداشده با ویرگول |
| `flclashm-globalmode` | `false` | پنهان‌کردن انتخاب حالت global |
| `flclashm-androidsecure` | `true` | بستن mixed-port در Android |
| `flclashm-custom` | `add/update` | زمان اعمال ظاهر |
| `announce` | `text/base64:…` | اعلان |
| `support-url` | `URL` | پشتیبانی |
| `x-hwid-max-devices-reached` | `—` | رسیدن به محدودیت دستگاه |
| `x-hwid-not-supported` | `—` | عدم پشتیبانی HWID |

`flclashm-hex`: رنگ hexadecimal شش/هشت‌رقمی با `#` اختیاری، سپس نوع Material 3 و `pureblack`. انواع: `tonalSpot`، `fidelity`، `monochrome`، `neutral`، `vibrant`، `expressive`، `content`، `rainbow`، `fruitSalad`.

جفت‌های `flclashm-view` با `;` جدا می‌شوند؛ همهٔ کلیدها اختیاری‌اند:

| کلید | مقادیر مجاز |
|------|-------------|
| `type` | `list`، `tab` |
| `sort` | `none`، `delay`، `name` |
| `layout` | `loose`، `standard`، `tight` |
| `icon` | `icon` (یا `standard`)، `none` |
| `card` | `expand`، `shrink`، `min`، `oneline` |

پرچم‌های `flclashm-settings`:

| پرچم | چه فعال می‌کند |
|------|----------------|
| `autostart` | اجرا/اتصال خودکار (از جمله پس از راه‌اندازی مجدد) |
| `autoupdate` | بررسی خودکار به‌روزرسانی |
| `autorun` | اجرای برنامه هنگام شروع سیستم *(دسکتاپ)* |
| `shadowstart` | اجرای خاموش (پس‌زمینه) |
| `minimize` | کوچک‌سازی به سینی هنگام خروج *(دسکتاپ)* |

</details>

</div>
