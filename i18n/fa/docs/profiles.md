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

در `mode: auto` راهبردها آزمایش و نتیجه برای هر شبکهٔ فیزیکی ذخیره می‌شود (تا 16 شبکه، بدون دسترسی به SSID). پس از مهلت راه‌اندازی، راهبرد موقت استفاده و انتخاب در پس‌زمینه ادامه می‌یابد. کش، نتیجه را تأییدشده یا موقت علامت می‌زند؛ راهبرد موقت از `retry-after` خود استفاده می‌کند. `mode: manual` از `strategy` استفاده می‌کند؛ بدون `mode`، وجود `strategy` حالت manual و نبود آن حالت auto را انتخاب می‌کند.

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
| `strategy-test.sni` | `google.com` | نام میزبان برای جای‌گذاری `{sni}` |
| `strategy-test.dns-resolver` | `https://1.1.1.1/dns-query` | حل‌کنندهٔ DoH نشانی تست؛ `system` از حل‌کنندهٔ سیستم استفاده می‌کند |
| `strategy-test.timeout` | `5s` | مهلت هر بررسی |
| `strategy-test.requests` | `1` | درخواست به‌ازای هر راهبرد |
| `strategy-test.request-concurrency` | `4` | درخواست‌های HTTP موازی درون یک نامزد |
| `strategy-test.min-success-ratio` | `1.0` | کمترین نسبت درخواست‌های موفق |
| `strategy-selection.strategy-concurrency` | `4` | راهبردهای هم‌زمان بررسی‌شونده |
| `strategy-selection.startup-timeout` | `15s` | بودجهٔ انتخاب پیش از شروع نود |
| `strategy-selection.continue-in-background` | `true` | ادامهٔ فهرست در پس‌زمینه پس از fallback |
| `strategy-selection.fallback-strategy` | راهبرد داخلی | راهبرد موقت اگر انتخاب به‌موقع تمام نشد |
| `strategy-selection.retry-after` | `5m` | مکث پیش از انتخاب تازه پس از fallback |
| `strategy-selection.cache.ttl` | `7d` | عمر کش |
| `strategy-selection.cache.recheck-after` | `1d` | فاصلهٔ بررسی مجدد |
| `strategy-selection.cache.failure-threshold` | `2` | تعداد خطا تا بازنشانی کش |

</details>

<a id="olcrtc"></a>

### OlcRTC

<div dir="ltr">

```yaml
proxies:
  - name: "rtc"
    type: olcrtc
    provider: jitsi
    room: "https://meet.example.org/room"
    encryption-key: "<64-hex-key>"
    transport: datachannel
    dns-server: "1.1.1.1:53"
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "rtc"]
```

</div>

فقط حالت کلاینت CNC مجاز است. به‌جای `<64-hex-key>` کلید سرور را قرار دهید: دقیقاً 64 نویسهٔ hexadecimal. `provider: none` به `engine`، `engine-url`، `engine-token` نیاز دارد؛ برای سایر ارائه‌دهندگان این فیلدها ممنوع‌اند. `profiles`، `failover`، `video.hw`، listener محلی و کلید از فایل مجاز نیستند.

`dns-server: system` از نخستین DNS شبکهٔ فیزیکی Android استفاده می‌کند: `host:53` برای IPv4 و `[IPv6]:53` برای IPv6. تغییر آن نود فعال وابسته را دوباره اجرا می‌کند. اگر DNS در دسترس نباشد، راه‌اندازی فوراً با خطای `physical DNS is unavailable` متوقف می‌شود. خطای راه‌اندازی هنگام اعمال نقشه، اعمال آن را متوقف می‌کند؛ پس از بیدارسازی ناموفق در پس‌زمینه، مکث `retry-after` اعمال می‌شود. کلاینت و سرور باید از OLC2 و OLVC 5 پشتیبانی کنند.

نسخهٔ داخلی از [فورک Ghostlane](https://github.com/ghostlane-project/olcrtc) است.
برای سرویس‌های جدید از ترکیب‌های زیر استفاده کنید:

| `provider` | `transport` | `room` | نیاز اضافی |
|---|---|---|---|
| `vkcalls` | `vp8channel` یا `videochannel` | `https://vk.ru/call/join/<id>` | لینک ورود تماس VK؛ `provider-token` غیرخالی ممنوع است |
| `mtslink` | `vp8channel` | `https://my.mts-link.ru/j/<owner>/<event>` | جلسهٔ دائمی MTS Link |
| `salutejazz` | `datachannel` | `<code>:<password>` | کد و رمز اتاق SaluteJazz |
| `max` | `datachannel` | `https://max.ru/joincall/<hash>` | `provider-token` الزامی: calls session key یا calls token در MAX |

توکن فقط در پیکربندی خصوصی به فرایند OlcRTC داده می‌شود؛ پروفایل حاوی آن را منتشر نکنید.
ترکیب پشتیبانی‌نشدهٔ ارائه‌دهنده و transport پیش از اجرای فرایند رد می‌شود.

<details>
<summary>فیلدها و انتقال OlcRTC</summary>

| پارامتر | توضیح |
|---------|-------|
| `provider` | ارائه‌دهندهٔ اتصال: `jitsi`، `telemost`، `wbstream`، `salutejazz`، `vkcalls`، `mtslink`، `max`، `none` |
| `room` | URL یا شناسهٔ اتاق؛ به‌جز `provider: none` الزامی است |
| `encryption-key` | کلید رمزنگاری 256بیتی — **دقیقاً 64 کاراکتر هگز** |
| `transport` | ترابری: `datachannel`، `vp8channel`، `seichannel`، `videochannel` |
| `dns-server` | الزامی: `host:port` یا `system` |
| `transport-options` | گزینه‌های اختیاری transport انتخاب‌شده؛ برای `datachannel` ممنوع است |

برای `datachannel`، بخش `transport-options` ممنوع است. پیش‌فرض `vp8channel`: مقدار `fps: 30` و `batch-size: 64`؛ برای `seichannel` همچنین `fragment-size: 900` و `ack-timeout: 2s`. در `videochannel`: فیلدهای `codec` (`qrcode`/`tile`)، `width`، `height`، `fps`، `fragment-size`، `qr-recovery`، `tile-module`، `tile-rs`. پیش‌فرض: `qrcode`، اندازهٔ 1920×1080 و `qr-recovery: low`؛ برای tile اندازهٔ 1080×1080 است. `bitrate` قدیمی پذیرفته اما نادیده گرفته می‌شود.

<div dir="ltr">

```yaml
proxies:
- name: rtc
  type: olcrtc
  provider: jitsi
  room: https://meet.example.org/room
  encryption-key: "<64-hex-key>"
  transport: seichannel
  dns-server: 1.1.1.1:53
  transport-options:
    fps: 30
    batch-size: 64
    fragment-size: 900
    ack-timeout: 2s
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - rtc
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
| `8.8.8.8` | یک resolver روی پورت 53 |
| `1.1.1.1:5353` | یک resolver با پورت اختصاصی |
| `192.168.1.0/30` | CIDR تا 65536 نشانی. در IPv4 با بیش از 2 نشانی، اولین و آخرین کنار گذاشته می‌شوند؛ `/31` و `/32` کامل حفظ می‌شوند. در IPv6 با بیش از 2 نشانی، اولین کنار گذاشته می‌شود |
| `https://…` | resolverها از یک فهرست راه دور |

هر پروفایل حداکثر 32 فهرست HTTPS دارد؛ آدرس دانلود نباید اعتبارنامه، fragment یا آدرس سرور محلی داشته باشد؛ IP/CIDR خصوصی داخل فهرست مجاز است. محدودیت پاسخ: 1 MiB و 15 ثانیه؛ تغییرمسیر ممنوع است. در خطا حتی پس از `refresh` از کش قبلی استفاده می‌شود؛ بدون کش، از منبع صرف‌نظر می‌شود. `refresh` هنگام اعمال پروفایل بررسی می‌شود.

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

کش به حل‌کننده‌ها، `domains` و نسخهٔ StormDNS وابسته است. `startup.max-age` رشتهٔ مدت با تعداد صحیح روز، از `0s` تا `365d` است (پیش‌فرض `30d`؛ `720h` معتبر است ولی عدد `30` معتبر نیست). بدون کش مناسب اسکن تکرار می‌شود. تغییر DNS سیستم کش MTU را پاک و نودهای فعال وابسته را بدون UI دوباره اجرا می‌کند. DNS/SOCKS محلی، فایل حل‌کننده، مسیر لاگ و `startup.mode: ask` در پروفایل ممنوع‌اند.

</details>

<details>
<summary>پیش‌تنظیم‌ها و تنظیم دقیق</summary>

ترتیب: مقادیر پیش‌فرض → `preset` → فیلدهای صریح. مدت‌ها رشتهٔ دارای واحد هستند (`600ms`، `30s`، `24h`، `30d`). مقادیر خارج از محدوده پیش از اجرا رد می‌شوند.

| `preset` | تکرار (upload / download / upload-setup / download-setup) | فشرده‌سازی |
|----------|-------------------------------------------------------------|------------|
| `messenger` (پیش‌فرض) | 1 / 7 / 3 / 8 | `lz4` |
| `balanced` | 2 / 5 / 3 / 6 | `lz4` |
| `bulk` | 3 / 3 / 4 / 4 | `zstd` |

<div dir="ltr">

```yaml
proxies:
- name: storm
  type: stormdns
  domains:
  - v.example.com
  encryption: chacha20
  encryption-key: "<key>"
  preset: bulk
  duplication:
    upload: 2
  compression:
    upload: zlib
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - storm
```

</div>

| بلوک | فیلدها و مرزها |
|------|----------------|
| `duplication` | `upload`، `download`، `upload-setup`، `download-setup` — 1 تا 8 |
| `compression` | `upload`، `download` — `none`، `zstd`، `lz4`، `zlib`؛ `min-size` — 100 تا 65535 |
| `mtu.upload`، `mtu.download` | `min` — 1 تا 65535؛ `max` — 0 تا 65535 که در آن `0` سقف را برمی‌دارد |
| `arq` | `window` 1 تا 6000، `nack-max-gap` 0 تا 1500، `max-control-retries` 5 تا 5000، `max-data-retries` 60 تا 100000؛ بقیه مدت‌زمان‌اند |
| `ping` | فقط مدت‌زمان: بازه‌های `aggressive`/`lazy`/`cooldown`/`cold` و آستانه‌های `warm`/`cool`/`cold` |
| `runtime` | `workers` و `process-workers` 1 تا 64، اندازهٔ صف‌ها و استخرها، مدت‌زمان تلاش مجدد؛ `base-encode` پرچم است |

محدودیت‌های وابسته به‌طور کامل بررسی می‌شوند:

- `duplication.upload-setup` ≥ `upload`، `download-setup` ≥ `download`
- `mtu.<جهت>.max` ≥ `min`
- `arq.initial-rto` ≤ `max-rto`، `arq.control-initial-rto` ≤ `control-max-rto`
- `arq.nack-max-gap` ≤ `arq.window / 4`
- `ping.aggressive-interval` ≤ `lazy-interval` ≤ `cooldown-interval` ≤ `cold-interval`
- `ping.warm-threshold` ≤ `cool-threshold` ≤ `cold-threshold`
- `runtime.process-workers` ≥ `runtime.workers`
- `runtime.session-retry-base` ≤ `session-retry-max`

فیلدهای پروفایل با `core/backend/compile/storm_schema.json` به کلید بومی نگاشت می‌شوند؛ مانند `arq.window` → `ARQ_WINDOW_SIZE`.

</details>

<a id="activation"></a>

## 😴 نود ذخیرهٔ خوابیده

پیش‌فرض OlcRTC و StormDNS برابر `activation: auto` است: با انتخاب دستی یا خرابی گروه تحت نظر اجرا می‌شوند. نود باید عضو مستقیم گروه باشد. بدون انتخاب یا اتصال، پس از `sleep.idle` می‌خوابد؛ `0s` خواب را تا راه‌اندازی مجدد VPN غیرفعال می‌کند. برای اجرا همراه پروفایل از `activation: always` استفاده کنید.

`activation` و `connectivity-check` داخل نود مشخص در `proxies` قرار می‌گیرند. `activation: auto` به گروهِ دربرگیرندهٔ مستقیم و URL بیداری نیاز دارد (صریح یا به‌ارث‌رسیده از بررسی نود، گروه یا تنظیم برنامه)؛ در غیر این صورت پروفایل رد می‌شود. مدت این دو بخش باید مضرب ثانیه باشد (`1s`، `1m`)؛ `500ms` نامعتبر است.

<div dir="ltr">

```yaml
proxies:
- name: rtc
  type: olcrtc
  provider: jitsi
  room: https://meet.example.org/room
  encryption-key: "<64-hex-key>"
  transport: datachannel
  dns-server: 1.1.1.1:53
  activation:
    mode: auto
    wake:
      urls:
      - https://example.org/generate_204
      interval: 30s
      failures: 2
      retry-after: 5m
    sleep:
      idle: 15m
proxy-groups:
- name: main
  type: fallback
  url: https://example.org/generate_204
  proxies:
  - DIRECT
  - rtc
```

</div>

<details>
<summary>پارامترهای بیداری و خواب</summary>

| پارامتر | پیش‌فرض | توضیح |
|---------|---------|-------|
| `mode` | `auto` | `auto` نود ذخیره را می‌خواباند؛ `always` راه‌اندازی همیشگی قدیمی |
| `wake.urls` | زنجیرهٔ `connectivity-check` | آدرس‌های HTTP(S) عمومی برای وارسی گروه زیرنظر |
| `wake.interval` | `30s` | فاصلهٔ وارسی هنگام خواب |
| `wake.failures` | `2` | دورهای ناموفق پیاپی تا بیدارشدن |
| `wake.retry-after` | `5m` | مکث پس از راه‌اندازی ناموفق |
| `sleep.idle` | `15m` | مدت بدون اتصال و انتخاب تا خواب؛ `0s` یعنی تا راه‌اندازی مجدد VPN نخوابد |

</details>

<a id="checks"></a>

## 🩺 بررسی دسترسی

فرایند و پورت SOCKS همیشه بررسی می‌شوند. آدرس HTTP(S) از `connectivity-check.urls` نود، نزدیک‌ترین گروه یا آدرس تست عمومی برنامه گرفته می‌شود. `required: false` بررسی را در پس‌زمینه انجام می‌دهد؛ `true` به آدرس نیاز دارد و در شکست، راه‌اندازی را لغو و تغییرات را بازمی‌گرداند. هر پاسخ معتبر HTTP از جمله 4xx/5xx موفق است.

<div dir="ltr">

```yaml
proxies:
- name: naive
  type: naiveproxy
  server: example.com
  port: 443
  username: user
  password: pass
  connectivity-check:
    urls:
    - https://example.org/generate_204
    required: true
```

</div>

فقط URL عمومی HTTP(S) بدون اعتبارنامه یا fragment مجاز است. DNS پیش از درخواست بررسی می‌شود؛ ترافیک از SOCKS نود آزمایشی عبور می‌کند و مسیر مستقیم جایگزین ندارد. TLS نام اصلی میزبان را تأیید می‌کند.

<details>
<summary>همهٔ پارامترهای بررسی</summary>

| فیلد | پیش‌فرض | چه تعیین می‌کند |
|------|---------|-----------------|
| `urls` | — | حداکثر 16 آدرس برای بررسی (HTTP(S) عمومی، بدون اعتبارنامه یا fragment) |
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

قوانین پروفایل بر تنظیم دستی اولویت دارند. `include-package` فقط برنامه‌های فهرست‌شده و `exclude-package` سایر برنامه‌ها را از VPN عبور می‌دهد. یک حالت را انتخاب کنید. `include-package: []` یا `exclude-package: []` خالی در منبع، بدون منابع دیگر، قانون پروفایل ایجاد نمی‌کند؛ تنظیم عمومی اعمال می‌شود.

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

`flclashm-custom: add` هنگام افزودن و `update` در هر به‌روزرسانی فقط `hex`، `view`، `widgets` و `settings` را اعمال می‌کند؛ سایر هدرها به آن وابسته نیستند. `flclashm-settings` وقتی `overrideProviderSettings` خاموش باشد اعمال می‌شود: پرچم‌های موجود فعال و پرچم‌های غایب به `false` بازنشانی می‌شوند. `androidsecure` فقط mixed-port را می‌بندد و انتخاب VPN را حفظ می‌کند. گروه `GLOBAL` از `flclashm-override` / `flclashx-override` پشتیبانی می‌کند و اولی اولویت دارد.

<details>
<summary>مرجع هدرها و قالب‌ها</summary>

| هدر | مقدار | کاربرد |
|---|---|---|
| `flclashm-newdomain` / `flclashx-newdomain` | نام میزبان | میزبان تازهٔ URL اشتراک را ذخیره می‌کند؛ طرح، پورت و مسیر تغییر نمی‌کنند |
| `flclashm-background` | `URL[,opacity]` | پس‌زمینه؛ نمایانی اختیاری تصویر 1–100 |
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
| `profile-update-interval` | تعداد صحیح ساعت | فاصلهٔ به‌روزرسانی اشتراک؛ مقدار مثبت |
| `x-hwid-max-devices-reached` | `true` | رسیدن به محدودیت دستگاه |
| `x-hwid-not-supported` | `true` | عدم پشتیبانی HWID |

`flclashm-hex`: رنگ hexadecimal 6/8 رقمی با `#` اختیاری، سپس نوع Material 3 و `pureblack`. انواع: `tonalSpot`، `fidelity`، `monochrome`، `neutral`، `vibrant`، `expressive`، `content`، `rainbow`، `fruitSalad`.

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
| `autostart` | اتصال خودکار هنگام بازکردن برنامه (`ui.attach`) |
| `autoupdate` | بررسی خودکار به‌روزرسانی |
| `autorun` | اجرای برنامه هنگام شروع سیستم *(دسکتاپ)* |
| `shadowstart` | اجرای خاموش (پس‌زمینه) |
| `minimize` | کوچک‌سازی به سینی هنگام خروج *(دسکتاپ)* |

</details>

</div>
