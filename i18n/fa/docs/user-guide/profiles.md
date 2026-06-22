# نودهای داخلی

نودهای داخلی مستقیماً در پروفایل YAML تعریف می‌شوند و مانند پروکسی‌های معمولی کار می‌کنند. FlClashM خودش فرآیندهای لازم را اجرا و پورت‌ها را مدیریت می‌کند.

## ByeDPI

**نوع:** `byedpi`

دو حالت را پشتیبانی می‌کند:

### انتخاب خودکار استراتژی

کلاینت استراتژی‌ها را از لیست ByeByeDPI بررسی می‌کند، یکی را پیدا کرده و کش می‌کند.

```yaml
proxies:
  - name: "dpi-auto"
    type: byedpi
    mode: auto
    strategy-list: byebyeedpi
    test:
      urls:
        - "https://example.com/"
      sni: "example.com"
      timeout: 5
      requests: 1
      concurrency: 4
      min-success-ratio: 1.0
    cache:
      ttl: 604800
      recheck-after: 86400
      failure-threshold: 2
```

**پارامترها:**

| پارامتر | توضیحات |
|---------|---------|
| `strategy-list` | نام لیست استراتژی (`byebyeedpi`) |
| `test.urls` | آدرس‌های تست |
| `test.sni` | نام میزبان برای جایگزینی `{sni}` |
| `test.timeout` | زمان‌توقف هر تست به ثانیه (پیش‌فرض ۵) |
| `test.requests` | تعداد درخواست‌ها به ازای هر استراتژی (پیش‌فرض ۱) |
| `test.concurrency` | تست‌های موازی (پیش‌فرض ۴) |
| `test.min-success-ratio` | حداقل نسبت موفقیت (پیش‌فرض ۱.۰) |
| `cache.ttl` | عمر کش به ثانیه (پیش‌فرض ۷ روز) |
| `cache.recheck-after` | فاصله بررسی مجدد به ثانیه (پیش‌فرض ۱ روز) |
| `cache.failure-threshold` | تعداد خطا قبل از ابطال کش (پیش‌فرض ۲) |

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
```

**پارامترها:**

| پارامتر | توضیحات |
|---------|---------|
| `auth.provider` | ارائه‌دهنده احراز هویت (`jitsi`, `telemost`) |
| `room.id` | شناسه اتاق تماس ویدیویی |
| `crypto.key` | کلید رمزنگاری ۲۵۶ بیتی (hex) |
| `net.transport` | انتقال (`datachannel`, `vp8channel`) |

## NaiveProxy

**نوع:** `naiveproxy`

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
- تمام نودهای داخلی فقط با TCP کار می‌کنند (`udp: false` همیشه).
