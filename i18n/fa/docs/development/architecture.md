# معماری

FlClashM بر پایه FlClashX ساخته شده است. منطق محصول از پایه جدا شده تا به‌روزرسانی‌ها قابلیت‌های خاص را خراب نکنند.

## زنجیره اصلی

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan → EngineManager → EngineAdapter
```

| مرحله | توضیحات |
|-------|---------|
| **RawProfile** | پروفایل خام |
| **ProfileCompiler** | خواندن پروفایل و ساخت پیکربندی اجرا |
| **SecurityPolicy** | اعمال قوانین امنیتی Android |
| **RuntimePlan** | ساخت برنامه اجرای محیط اجرا |
| **EngineManager** | مدیریت چرخه حیات موتور |
| **EngineAdapter** | پل به `mihomo` |

## لایه‌ها

1. **پایه FlClashX** — رابط کاربری، ناوبری، مسیر پایه اجرا.
2. **لایه محصول** (`lib/product/**`) — کامپایل پروفایل، امنیت، به‌روزرسانی‌ها.
3. **لایه اجرا** — `mihomo`، نودهای داخلی.
4. **لایه پلتفرم** — VPN اندروید، سرویس، اعلان‌ها.

## مرز پایه و محصول

کد پایه خارج از `lib/product/**` فقط از طریق نقاط یکپارچه‌سازی در `tool/product_touchpoints.json` به لایه محصول دسترسی دارد.

```bash
dart tool/check_product_boundaries.dart
```

## سرویس‌های اصلی

| سرویس | مسئول |
|-------|-------|
| `ProfileCompiler` | خواندن و نرمال‌سازی پروفایل |
| `SecurityPolicy` | قوانین امنیتی اجباری |
| `EngineManager` | چرخه حیات موتور |
| `AppUpdateService` | بررسی و نصب به‌روزرسانی‌ها |
| `AccessControlService` | راه‌اندازی و مجوز Android VPN |
