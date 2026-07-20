# نودهای داخلی

نودهای داخلی مستقیماً در پروفایل YAML تعریف می‌شوند و مانند پروکسی‌های معمولی کار می‌کنند. FlClashM خودش فرآیندهای لازم را اجرا و پورت‌ها را مدیریت می‌کند.

## ByeDPI

**نوع:** `byedpi`

UDP به‌طور پیش‌فرض فعال است. برای غیرفعال کردن آن در نود، `udp: false` را تنظیم کنید.

دو حالت را پشتیبانی می‌کند:

### انتخاب خودکار استراتژی

کلاینت استراتژی‌ها را از لیست ByeByeDPI بررسی می‌کند، یکی را پیدا کرده و کش می‌کند.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
```

**پارامترها:**

| پارامتر | توضیحات |
|---------|---------|
| `strategy-list` | نام لیست استراتژی؛ پیش‌فرض `byebyeedpi` |
| `strategies` | فهرست مرتب استراتژی‌های سفارشی به‌جای `strategy-list` |
| `strategy-test.urls` | آدرس‌های انتخاب استراتژی؛ پیش‌فرض endpoint داخلی YouTube است |
| `strategy-test.sni` | نام میزبان برای جایگزینی `{sni}` |
| `strategy-test.timeout` | زمان‌توقف هر تست به ثانیه (پیش‌فرض ۵) |
| `strategy-test.requests` | تعداد درخواست‌ها به ازای هر استراتژی (پیش‌فرض ۱) |
| `strategy-test.concurrency` | درخواست‌های HTTP موازی در یک استراتژی (پیش‌فرض ۴) |
| `strategy-test.min-success-ratio` | حداقل نسبت موفقیت (پیش‌فرض ۱.۰) |
| `selection.concurrency` | تعداد استراتژی‌هایی که هم‌زمان بررسی می‌شوند (پیش‌فرض ۴) |
| `selection.foreground-timeout` | بودجه زمانی کل پیش از اجرای نود، به ثانیه (پیش‌فرض ۱۵) |
| `selection.background` | ادامه بررسی پس از اجرای fallback (پیش‌فرض `true`) |
| `fallback-args` | آرگومان‌های موقت fallback پس از پایان بودجه foreground |
| `cache.ttl` | عمر کش به ثانیه (پیش‌فرض ۷ روز) |
| `cache.recheck-after` | فاصله بررسی مجدد به ثانیه (پیش‌فرض ۱ روز) |
| `cache.retry-after` | فاصله تلاش دوباره پس از fallback موقت (پیش‌فرض ۵ دقیقه) |
| `cache.failure-threshold` | تعداد خطا قبل از ابطال کش (پیش‌فرض ۲) |

استراتژی‌ها در دسته‌های موازی و محدود بررسی می‌شوند. پس از پایان بودجه foreground،
ByeDPI فوراً با fallback اجرا می‌شود و بررسی بقیه فهرست در پس‌زمینه ادامه پیدا می‌کند.
هر پاسخ HTTP معتبر سرور، از جمله `4xx` و `5xx`، موفق محسوب می‌شود و fallback موقت
هیچ‌گاه به‌عنوان نتیجه تأییدشده ذخیره نمی‌شود.

اگر `mode` مشخص نشود، وجود `args` حالت دستی را انتخاب می‌کند و در غیر این صورت
حالت خودکار استفاده می‌شود. `strategy-test.urls` endpoint داخلی را بازنویسی می‌کند.

اگر هیچ استراتژی کار نکرد، از حالت پشتیبان استفاده می‌شود.

### استراتژی دستی

```yaml
proxies:
  - name: "dpi-fixed"
    type: byedpi
    mode: manual
    args: "--disorder 1 --auto=torst --tlsrec 1+s"
```

## OlcRTC

**نوع:** `olcrtc`

UDP پشتیبانی نمی‌شود؛ فقط `udp: false` مجاز است.

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
proxy-groups:
  - name: "main"
    type: fallback
    url: "https://example.org/generate_204"
    proxies: ["DIRECT", "rtc"]
```

**پارامترها:**

| پارامتر | توضیحات |
|---------|---------|
| `auth.provider` | ارائه‌دهنده احراز هویت (`jitsi`, `telemost`, `wbstream`, `none`) |
| `room.id` | شناسه اتاق تماس ویدیویی |
| `crypto.key` | کلید رمزنگاری ۲۵۶ بیتی (hex) |
| `net.transport` | انتقال (`datachannel`, `vp8channel`, `seichannel`, `videochannel`) |
| `net.dns` | سرور DNS الزامی با قالب `host:port` |

### فعال‌سازی

OlcRTC به‌طور پیش‌فرض یک نود ذخیره است: پیکربندی از قبل آماده می‌شود، اما فرایند تا شکست بررسی گروه اصلی یا انتخاب دستی OlcRTC در حالت خواب می‌ماند. شکل کوتاه:

```yaml
activation: auto
# activation: always  # رفتار قدیمی: اجرا همراه با VPN
```

شکل کامل:

```yaml
activation:
  mode: auto
  wake:
    urls: ["https://example.org/generate_204"]
    interval: 30
    failures: 2
    retry-after: 300
  sleep:
    idle: 900
```

| پارامتر | پیش‌فرض | توضیح |
|---------|---------|-------|
| `mode` | `auto` | در `auto` نود ذخیره می‌خوابد؛ `always` اجرای دائمی قبلی را برمی‌گرداند |
| `wake.urls` | زنجیره `connectivity-check` | آدرس‌های عمومی HTTP(S) برای بررسی گروه تحت نظر |
| `wake.interval` | `30` | فاصله دورهای watchdog هنگام خواب، بر حسب ثانیه |
| `wake.failures` | `2` | تعداد شکست‌های پیاپی لازم برای بیدارشدن |
| `wake.retry-after` | `300` | زمان انتظار پس از تلاش ناموفق بیدارسازی، بر حسب ثانیه |
| `sleep.idle` | `900` | زمان بدون ترافیک و انتخاب تا خواب دوباره؛ `0` یعنی بیدار ماندن تا راه‌اندازی مجدد VPN |

در حالت `auto`، نود باید عضو مستقیم حداقل یک گروه پروکسی باشد و آدرس بررسی باید از `wake.urls`، ‏`connectivity-check` نود، نزدیک‌ترین گروه دربرگیرنده یا URL آزمایش سراسری برنامه به دست آید. پس از بیدارسازی، کلاینت خود OlcRTC را فوراً آزمایش می‌کند. اگر در مدت `sleep.idle` هیچ اتصال فعالی از آن عبور نکند و هیچ گروه دربرگیرنده‌ای آن را انتخاب نکرده باشد، فرایند دوباره متوقف می‌شود؛ انتخاب دستی آن را فوراً بیدار می‌کند.

اکنون حتی با حذف `activation` نیز مقدار پیش‌فرض `auto` است. برای بازگرداندن کامل رفتار همیشه‌روشن قبلی، `activation: always` را تنظیم کنید.

## NaiveProxy

**نوع:** `naiveproxy`

UDP پشتیبانی نمی‌شود؛ فقط `udp: false` مجاز است.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    proxy: "https://user:pass@example.com"
```

## محدودیت‌ها

- نودهای داخلی فقط در بخش `proxies` قابل تعریف هستند.
- کلاینت آدرس‌ها و پورت‌های محلی را خودکار مدیریت می‌کند.
- پروفایل نمی‌تواند `listen`، `server`، `port`، `ip` را تنظیم کند.
- ByeDPI به‌طور پیش‌فرض از UDP استفاده می‌کند و با `udp: false` می‌توان آن را
  غیرفعال کرد. NaiveProxy و OlcRTC از UDP پشتیبانی نمی‌کنند.
