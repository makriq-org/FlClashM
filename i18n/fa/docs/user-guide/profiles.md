# 🧩 نودهای داخلی

ابرقدرت FlClashM: **نودهای ویژه مستقیماً در پروفایل YAML توصیف می‌شوند** و مانند پروکسی‌های معمولی رفتار می‌کنند. کلاینت فرایندهای لازم را اجرا می‌کند، پورت‌های محلی به آن‌ها می‌دهد و آن‌ها را در مسیریابی `mihomo` می‌گنجاند. در قوانین می‌توانید آزادانه ترکیبشان کنید — یک سایت از `byedpi`، دیگری از `olcrtc` و بقیه مستقیم.

چهار نوع پشتیبانی می‌شود:

| نوع | چه می‌کند | کِی به کار می‌آید |
|-----|-----------|-------------------|
| 🛡 [`byedpi`](#-byedpi) | عبور از DPI با دستکاری بسته | منابع مسدودشده «از داخل»: YouTube، Discord و… |
| 📞 [`olcrtc`](#-olcrtc) | تونلی روی WebRTC با استتار تماس تصویری | عبور از لیست سفید (مثلاً از Yandex Telemost / Jitsi) |
| 🌩 [`stormdns`](#-stormdns) | تونل داخل پرس‌وجوهای DNS | عبور از لیست‌های سفید، جایی که تنها DNS عبور داده می‌شود |
| 🎭 [`naiveproxy`](#-naiveproxy) | تقلید از ترافیک Chrome | عبور از لیست سیاه، مقاومت در برابر اثرانگشت TLS |

> [!NOTE]
> نودهای داخلی **فقط** در بخش `proxies` تعریف می‌شوند. آدرس‌ها و پورت‌های محلی را کلاینت تعیین می‌کند — نمی‌توانید در پروفایل آن‌ها را بگذارید.

---

## 🔍 بررسی راه‌اندازی

پیش از آماده دانستن یک نود، FlClashM همیشه دو چیز را بررسی می‌کند: **فرایند زنده** و **پورت SOCKS محلی باز**. این برای NaiveProxy، OlcRTC، ByeDPI و StormDNS برقرار است.

افزون بر این می‌توانید یک **بررسی سرتاسری** فعال کنید — یک درخواست واقعی HTTP(S) که دقیقاً از پورت SOCKS نود عبور می‌کند:

```yaml
connectivity-check:
  urls:
    - "https://example.org/generate_204"
  required: true
  timeout: 5s
  startup-timeout: 30s
  retry-interval: 1s
  requests: 1
  concurrency: 1
  min-success-ratio: 1.0
```

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

**آدرس چگونه انتخاب می‌شود.** به‌ترتیب: `connectivity-check.urls` خودِ نود ← آدرس نزدیک‌ترین گروه دربرگیرنده ← آدرس بررسی سراسری برنامه. اگر آدرسی نباشد، فقط بررسی فرایند و پورت می‌ماند.

> [!WARNING]
> **تفاوت `required: false` و `required: true`:**
> - `false` — بررسی در پس‌زمینه اجرا می‌شود، راه‌اندازی را به تأخیر نمی‌اندازد و در صورت شکست فقط در لاگ می‌نویسد.
> - `true` — نبودِ آدرس پروفایل را **رد** می‌کند و شکست بررسی راه‌اندازی را با بازگردانی نقشهٔ آماده‌شده **لغو** می‌کند.
>
> **هر** پاسخ معتبر HTTP موفق شمرده می‌شود، از جمله `4xx` و `5xx`. فقط آدرس‌های HTTP(S) عمومی بدون اعتبارنامه یا fragment مجازند.

---

## 🛡 ByeDPI

**نوع:** `byedpi` · UDP به‌طور پیش‌فرض فعال است (با `udp: false` خاموش می‌شود)

ByeDPI با «خراب‌کردن» بسته‌ها به‌گونه‌ای که فیلتر نتواند اتصال را بشناسد، از DPI عبور می‌کند. این نود دو حالت دارد.

### 🤖 انتخاب خودکار راهبرد

کلاینت راهبردهای فهرست ByeByeDPI را می‌پیماید، یکی کارآمد می‌یابد و کش می‌کند — در راه‌اندازی سرد بی‌درنگ استفاده می‌شود.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    strategies:
      - builtin:byebyeedpi
      - "--disorder 1"
      - "https://example.org/byedpi-strategies.txt"
```

نحوهٔ کار: نامزدها در گروه‌های کوچک به‌موازات بررسی می‌شوند. اگر در بودجهٔ تعیین‌شده چیزی یافت نشد، نود با یک راهبرد موقت (fallback) شروع می‌شود و باقی فهرست در پس‌زمینه بررسی می‌گردد. راهبرد کارآمدِ یافته‌شده به‌صورت اتمی وارد نقشه و ذخیره می‌شود.

<details>
<summary>⚙️ همهٔ پارامترهای حالت خودکار</summary>

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

فایل HTTPS در هر خط یک راهبرد دارد؛ خط‌های خالی و خط‌هایی که با `#` آغاز
می‌شوند نادیده گرفته می‌شوند. محدودیت‌های HTTPS عمومی، اندازه، timeout و
stale-cache همان محدودیت‌های فهرست StormDNS است.

> [!NOTE]
> `strategy-test` **فقط** هنگام انتخاب خودکار به کار می‌رود و endpoint آزمایشی داخلی را بازنویسی می‌کند — جایگزین `connectivity-check` نیست. نتیجهٔ تأییدشده و fallback موقت **جداگانه** کش می‌شوند: fallback تلاش‌های بعدی انتخاب را در مدت TTL معمول مسدود نمی‌کند. هر بررسی HTTP موفق شمرده می‌شود، از جمله `4xx` و `5xx`.
>
> [!CAUTION]
> بخش قدیمی `test` دیگر پشتیبانی نمی‌شود — آن را به `strategy-test` تغییر نام دهید.

### ✍️ راهبرد دستی

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    strategy: "--disorder 1 --auto=torst --tlsrec 1+s"
```

> [!TIP]
> در پروفایل‌های تازه `mode` را صریح بنویسید؛ نبود آن حالت خودکار را انتخاب می‌کند.

---

## 📞 OlcRTC

**نوع:** `olcrtc` · UDP پشتیبانی نمی‌شود (فقط `udp: false` مجاز است)

OlcRTC ترافیک را در WebRTC می‌پیچد و آن را به‌شکل یک تماس تصویری معمولی از یک سرویس مجاز جا می‌زند — تا اتصال از لیست‌های سفید بگذرد.

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

| پارامتر | توضیح |
|---------|-------|
| `provider` | ارائه‌دهندهٔ اتصال: `jitsi`، `telemost`، `wbstream`، `none` |
| `room` | شناسهٔ اتاق تماس تصویری |
| `encryption-key` | کلید رمزنگاری ۲۵۶بیتی — **دقیقاً ۶۴ کاراکتر هگز** |
| `transport` | ترابری: `datachannel`، `vp8channel`، `seichannel`، `videochannel` |
| `dns-server` | سرور DNS الزامی به‌شکل `آدرس:پورت` |
| `transport-options` | گزینه‌های transport انتخاب‌شده؛ برای `datachannel` ممنوع است |

گزینه‌ها به transport وابسته‌اند: `vp8channel` فیلدهای `fps` و `batch-size` را
می‌پذیرد؛ `seichannel` علاوه بر آن‌ها `fragment-size` و `ack-timeout` با مقدار
duration رشته‌ای را می‌پذیرد؛ `videochannel` فیلدهای `codec`، `width`، `height`،
`fps`، `bitrate`، `fragment-size`، `qr-recovery`، `tile-module` و `tile-rs` را
می‌پذیرد.

```yaml
transport: seichannel
transport-options:
  fps: 30
  batch-size: 64
  fragment-size: 900
  ack-timeout: 2s
```

> [!TIP]
> برای `wbstream`، `vp8channel` توصیه می‌شود: حالت مهمانِ این ارائه‌دهنده اجازهٔ انتشار کانال داده را نمی‌دهد. فیلدهای `transport-options.fps` و `transport-options.batch-size` اجباری‌اند.

`profiles`، `failover` و `video.hw` از قرارداد عمومی حذف شده‌اند. چند حالت OlcRTC را به‌صورت نودهای جدا و در یک گروه Mihomo تعریف کنید. `provider: none` به `engine`، `engine-url` و `engine-token` نیاز دارد و providerهای دیگر این فیلدها را نمی‌پذیرند.

> [!WARNING]
> خطای فیلدهای الزامی همان هنگام اعتبارسنجی پروفایل دیده می‌شود. اگر فرایند OlcRTC بعداً از کار بیفتد، کلاینت **کد خروج و آخرین خطوط خروجی** را نشان می‌دهد نه اینکه منتظر timeout پورت بماند.

---

## 🌩 StormDNS

**نوع:** `stormdns` · از UDP پشتیبانی نمی‌کند (فقط `udp: false` مجاز است)

StormDNS ترافیک TCP را در پرس‌وجوهای معمولی DNS به یک رزالور مجاز می‌پیچد — تا اتصال از لیست‌های سفید بگذرد. هدف همان هدف OlcRTC است، اما حامل فرق دارد — DNS: این نود برای شبکه‌هایی است که تنها پرس‌وجوهای DNS را عبور می‌دهند. **به‌طور محسوسی کندتر** از بقیه است.

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

### 🔑 فیلدهای الزامی

`domains`، `encryption` و `encryption-key` **الزامی‌اند و مقدار پیش‌فرض ندارند**: StormDNS هیچ توافقی در پروتکل انجام نمی‌دهد، پس هر سه باید دقیقاً با سرور یکی باشند.

| فیلد | توضیح |
|------|-------|
| `domains` | دامنه‌های واگذارشده به سرور StormDNS |
| `encryption` | `none`، `xor`، `chacha20`، `aes-128-gcm`، `aes-192-gcm`، `aes-256-gcm` |
| `encryption-key` | کلید مشترک؛ باید با سرور یکی باشد |

> [!WARNING]
> حالت‌های `none` و `xor` **محتوا را محافظت نمی‌کنند** و گردانندهٔ resolver می‌تواند ترافیک شما را ببیند. فقط وقتی سرور لازم دارد از آن‌ها استفاده کنید.

### 📍 Resolverها

`resolvers` یک فهرست واحد از منابع است که به ترتیب پردازش می‌شود:

| مورد | چه اضافه می‌کند |
|------|-----------------|
| `system` | DNS شبکهٔ فیزیکی (نه VPN) |
| `8.8.8.8` | یک resolver روی پورت ۵۳ |
| `1.1.1.1:5353` | یک resolver با پورت اختصاصی |
| `192.168.1.0/30` | CIDR: در IPv4 نشانی شبکه و broadcast برداشته نمی‌شوند؛ بازهٔ بزرگ‌تر از ۶۵۵۳۶ نشانی رد می‌شود |
| `https://…` | resolverها از یک فهرست راه دور |

اگر `resolvers` نباشد یا خالی باشد، `[system]` استفاده می‌شود. پس از باز شدن همهٔ منابع، تکراری‌ها بر اساس IP حذف می‌شوند: اولین مورد به همراه پورتش برنده است. اگر فهرست نهایی خالی باشد، پروفایل اعمال نمی‌شود.

نشانی فهرست‌ها فقط با HTTPS مجاز است، بدون نام کاربری/گذرواژه و بدون fragment؛ localhost و نشانی‌های محلی رد می‌شوند — اما IP و CIDR خصوصی **داخل** فهرست مجاز است. هر پروفایل می‌تواند حداکثر به ۳۲ نشانی فهرست متفاوت اشاره کند. پاسخ حداکثر ۱ مبی‌بایت با مهلت ۱۵ ثانیه. هر نشانی جداگانه کش می‌شود: اگر در دسترس نباشد، آخرین نسخهٔ ذخیره‌شده حتی پس از پایان `refresh` استفاده می‌شود؛ و اگر نسخه‌ای نباشد، آن نشانی رد می‌شود و بقیهٔ منابع کار می‌کنند.

| `resolver-policy` | پیش‌فرض | توضیح |
|-------------------|---------|-------|
| `refresh` | `24h` | فاصلهٔ به‌روزرسانی فهرست‌های راه دور |
| `strategy` | `least-loss` | `random`، `round-robin`، `least-loss`، `lowest-latency` |
| `auto-disable` | `true` | غیرفعال‌کردن resolverهایی که پاسخ نمی‌دهند |
| `recheck` | `true` | آزمایش دوره‌ای resolverهای غیرفعال |

`refresh` هنگام اعمال پروفایل بررسی می‌شود — تایمر دائمی جداگانه‌ای وجود ندارد.

### 🎚 پیش‌تنظیم‌ها

`preset` تکرار بسته‌ها و فشرده‌سازی را تعیین می‌کند. ترتیب اعمال: **پیش‌فرض‌های StormDNS ← preset ← فیلدهای صریح**.

| `preset` | تکرار (upload / download / upload-setup / download-setup) | فشرده‌سازی |
|----------|-------------------------------------------------------------|------------|
| `messenger` (پیش‌فرض) | ۱ / ۷ / ۳ / ۸ | `lz4` |
| `balanced` | ۲ / ۵ / ۳ / ۶ | `lz4` |
| `bulk` | ۳ / ۳ / ۴ / ۴ | `zstd` |

هر فیلد را می‌توان جداگانه بازنویسی کرد؛ ساختار جداگانه‌ای لازم نیست:

```yaml
preset: bulk
duplication:
  upload: 2
compression:
  upload: zlib
```

تنظیم دقیق در بلوک‌های `duplication`، `compression`، `mtu`، `arq`، `ping` و `runtime` قرار دارد. همهٔ مدت‌زمان‌ها، از جمله فیلدهای مشترک `activation` و `connectivity-check`، رشته‌ای همراه واحد هستند (`600ms`، `30s`، `24h`، `30d`).

> [!NOTE]
> StormDNS مقادیر خارج از محدوده را بی‌صدا می‌بُرد. FlClashM به‌جای آن **پیش از اجرا خطا می‌دهد**.

<details>
<summary>📐 مرزهای تنظیم دقیق</summary>

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

### 🚀 راه‌اندازی

| `startup.mode` | چه می‌کند |
|----------------|-----------|
| `scan` | پویش کامل resolverها (کندترین شروع) |
| `cached` (پیش‌فرض) | شروع از کش بدون بررسی دوبارهٔ MTU |
| `verified` | شروع از کش با بررسی دوبارهٔ MTU |

`startup.max-age` (پیش‌فرض `30d`) سن مجاز کش قابل استفاده را محدود می‌کند و باید تعداد صحیحی از روزها باشد.

> [!NOTE]
> نخستین اجرا از مسیر پویش رزالورها می‌گذرد و ممکن است تا دو دقیقه طول بکشد — بودجهٔ بررسی همین را در نظر گرفته است.

کش کاری به فهرست نهایی resolverها، `domains` و نسخهٔ StormDNS گره خورده است. تغییر منابع پروفایل، `domains` یا نسخه، کش تازه‌ای می‌سازد و کش قدیمی تنها پس از اعمال موفق پروفایل حذف می‌شود. تغییر DNS شبکهٔ فیزیکی، کش فعلی را پیش از اجرای دوبارهٔ نود پاک می‌کند. اگر کش مناسبی نباشد یا StormDNS آن را نپذیرد، خودش به پویش کامل برمی‌گردد — این رفتار عادی است.

پوشهٔ لاگ، فایل resolver، پورت محلی و SOCKS5 در اختیار برنامه‌اند و در پروفایل قابل تعیین نیستند.

### 📶 DNS سیستمی

وقتی `resolvers` شامل `system` باشد (یا اصلاً نباشد)، نود به DNS شبکهٔ فیزیکی وابسته است. با تغییر آن‌ها، پلتفرم خودش فایل resolver را بازنویسی می‌کند، کش کاری را پاک می‌کند و **فقط** نودهای وابستهٔ فعال را دوباره اجرا می‌کند — از جمله در راه‌اندازی سرد بدون اجرای رابط کاربری. نیازی به bypass جداگانه نیست: بستهٔ خود برنامه از مسیریابی VPN مستثنا شده است.

---

## 🎭 NaiveProxy

**نوع:** `naiveproxy` · UDP پشتیبانی نمی‌شود (فقط `udp: false` مجاز است)

NaiveProxy با استفاده از پشتهٔ شبکهٔ Chromium ترافیک را به‌شکل درخواست‌های معمولی Chrome استتار می‌کند — این در برابر اثرانگشت TLS و کاوش فعال مقاوم است.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

- **فیلدهای الزامی:** `name`، `type`، `server`، `port`، `username`، `password`.
- `transport` پیش‌فرض `https` است؛ `quic` هم مجاز است.
- اختیاری: `insecure-concurrency` (۱–۴)، `tunnel-timeout`، `idle-timeout`، `post-quantum`، نگاشت `headers`، `host-resolver-rules` و یک `connectivity-check` مشترک.

کلاینت یک URI با اعتبارنامهٔ escape‌شده به‌شکل امن می‌سازد، آن را به NaiveProxy می‌دهد و نود مربوط به `mihomo` را با یک SOCKS5 محلی جایگزین می‌کند.

> [!CAUTION]
> فیلد قدیمی `proxy` پشتیبانی نمی‌شود. `listen`، فایل‌های تشخیصی، زنجیرهٔ پروکسی و هر فیلد ناشناخته هنگام اعتبارسنجی پروفایل **رد** می‌شوند.

---

## 😴 فعال‌سازی: ذخیرهٔ خواب‌آلود (OlcRTC و StormDNS)

به‌طور پیش‌فرض OlcRTC و StormDNS مانند **نودهای پشتیبان** عمل می‌کنند: پیکربندی از پیش آماده است، اما فرایند می‌خوابد تا زمانی که گروه اصلی شکست بخورد یا کاربر نود را دستی انتخاب کند.

```yaml
activation: auto
# activation: always  # حالت قدیمی: شروع همراه با VPN
```

شکل کامل، کنترل بیدارشدن و خوابیدن را می‌دهد:

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

| پارامتر | پیش‌فرض | توضیح |
|---------|---------|-------|
| `mode` | `auto` | `auto` پشتیبان را می‌خواباند؛ `always` راه‌اندازی همیشگی قدیمی |
| `wake.urls` | زنجیرهٔ `connectivity-check` | آدرس‌های HTTP(S) عمومی برای وارسی گروه زیرنظر |
| `wake.interval` | `30s` | فاصلهٔ وارسی هنگام خواب |
| `wake.failures` | `2` | دورهای ناموفق پیاپی تا بیدارشدن |
| `wake.retry-after` | `5m` | مکث پس از راه‌اندازی ناموفق |
| `sleep.idle` | `15m` | مدت بدون اتصال و انتخاب تا خواب؛ `0s` یعنی تا راه‌اندازی مجدد VPN نخوابد |

**آنچه دربارهٔ `auto` مهم است:**
- نود باید مستقیماً عضو دست‌کم یک proxy group باشد.
- آدرس‌های بررسی باید از `wake.urls`، `connectivity-check` نود، نزدیک‌ترین گروه یا URL آزمایشی سراسری برنامه قابل تحلیل باشند.
- پس از بیدارشدن، کلاینت بی‌درنگ خودِ نود را بررسی می‌کند. اگر هیچ گروه دربرگیرنده‌ای آن را انتخاب نکرد و در مدت `sleep.idle` اتصال فعالی نبود — فرایند دوباره می‌خوابد.
- **انتخاب دستی بی‌درنگ نود را بیدار می‌کند.**

> [!NOTE]
> اکنون `auto` **حتی بدون فیلد `activation`** استفاده می‌شود. برای بازگردانی کامل رفتار پیشین، به‌صراحت `activation: always` بگذارید.

---

## 🚧 محدودیت‌ها

- نودهای داخلی فقط در بخش `proxies` تعریف می‌شوند.
- آدرس‌ها و پورت‌های محلی را خود کلاینت مدیریت می‌کند.
- پروفایل نمی‌تواند `listen` محلی بگذارد؛ برای NaiveProxy، `server` و `port` فقط سرور دور را توصیف می‌کنند.
- UDP: `byedpi` — فعال (با `udp: false` قابل خاموش‌کردن)؛ `naiveproxy`، `olcrtc` و `stormdns` از UDP پشتیبانی **نمی‌کنند**.

---

> 📎 جزئیات فنی چرخهٔ حیات نودها در [محیط اجرا](../development/runtime.md). تضمین‌های امنیتی در [سیاست امنیتی](../development/security.md).
>
> 🌍 زبان‌های دیگر: [Русский](../../../ru/docs/user-guide/profiles.md) · [English](../../../en/docs/user-guide/profiles.md) · [中文](../../../zh/docs/user-guide/profiles.md)
