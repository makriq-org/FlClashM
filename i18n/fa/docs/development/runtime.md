# محیط اجرا

## زنجیره پردازش

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan
```

پس از آن، چرخه حیات توسط `EngineManager` و `EngineAdapter` مدیریت می‌شود.

## نودهای داخلی

نودهای داخلی به‌عنوان پروکسی‌های معمولی در پروفایل تعریف می‌شوند. چرخه حیات آن‌ها توسط `BuiltInProxySupervisor` مدیریت می‌شود.

### naiveproxy

- **نوع:** `naiveproxy`
- **فیلدهای الزامی:** `name`, `proxy`
- کلاینت آدرس SOCKS5 محلی را خودکار انتخاب می‌کند
- با `config.json` تولیدشده خودکار اجرا می‌شود

### olcrtc

- **نوع:** `olcrtc`
- **فیلدهای الزامی:** `name`, `auth.provider`, `room.id`, `crypto.key`
- فقط در حالت CNC (کلاینت) کار می‌کند

### byedpi

- **نوع:** `byedpi`
- **حالت `manual`:** رشته `args` را می‌پذیرد
- **حالت `auto`:** استراتژی‌های ByeByeDPI را بررسی و نسخه کارآمد را کش می‌کند
- جایگزینی `{sni}` پشتیبانی می‌شود

## محدودیت‌ها

- نودهای داخلی فقط در بخش `proxies` کار می‌کنند
- آدرس‌ها و پورت‌های محلی توسط کلاینت تعیین می‌شوند
- ByeDPI در حالت `auto` فقط URLهای `test.urls` را بررسی می‌کند
