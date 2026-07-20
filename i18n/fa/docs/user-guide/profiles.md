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
```

**پارامترها:**

| پارامتر | توضیحات |
|---------|---------|
| `auth.provider` | ارائه‌دهنده احراز هویت (`jitsi`, `telemost`, `wbstream`, `none`) |
| `room.id` | شناسه اتاق تماس ویدیویی |
| `crypto.key` | کلید رمزنگاری ۲۵۶ بیتی (hex) |
| `net.transport` | انتقال (`datachannel`, `vp8channel`, `seichannel`, `videochannel`) |
| `net.dns` | سرور DNS الزامی با قالب `host:port` |

## NaiveProxy

**نوع:** `naiveproxy`

UDP پشتیبانی نمی‌شود؛ فقط `udp: false` مجاز است.

```yaml
proxies:
  - name: "naive"
    type: naiveproxy
    server: example.com
    port: 443
    username: user
    password: pass
```

فیلدهای الزامی عبارت‌اند از `name`، `type`، `server`، `port`، `username` و
`password`. مقدار پیش‌فرض `transport` برابر `https` است و `quic` نیز مجاز است.
فیلدهای اختیاری شامل `insecure-concurrency` (از ۱ تا ۴)، `tunnel-timeout`،
`idle-timeout`، `post-quantum`، نگاشت `headers`، `host-resolver-rules` و
`connectivity-check` مشترک هستند.

کلاینت اطلاعات ورود را escape می‌کند، URI داخلی NaiveProxy را می‌سازد و برای
Mihomo یک SOCKS5 محلی قرار می‌دهد. فیلد قدیمی `proxy` پشتیبانی نمی‌شود.
`listen`، فایل‌های تشخیصی، زنجیره پروکسی و فیلدهای ناشناخته هنگام اعتبارسنجی رد
می‌شوند.

## محدودیت‌ها

- نودهای داخلی فقط در بخش `proxies` قابل تعریف هستند.
- کلاینت آدرس‌ها و پورت‌های محلی را خودکار مدیریت می‌کند.
- پروفایل نمی‌تواند `listen` محلی را تنظیم کند؛ `server` و `port` در NaiveProxy
  فقط سرور راه‌دور را توصیف می‌کنند.
- ByeDPI به‌طور پیش‌فرض از UDP استفاده می‌کند و با `udp: false` می‌توان آن را
  غیرفعال کرد. NaiveProxy و OlcRTC از UDP پشتیبانی نمی‌کنند.
