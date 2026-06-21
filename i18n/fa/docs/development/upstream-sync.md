# همگام‌سازی با FlClashX

FlClashM بر پایه FlClashX ساخته شده است. منطق محصول جدا شده تا به‌روزرسانی ارزان بماند.

## اصل

- منطق محصول در `lib/product/**` قرار دارد
- کد خارج از `lib/product/**` فقط از طریق نقاط یکپارچه‌سازی به آن دسترسی دارد

## فرآیند به‌روزرسانی

1. FlClashX را در شاخه جداگانه‌ای بکشید
2. تضادها در `lib/product/**` را حل کنید
3. خارج از `lib/product/**` فقط فایل‌های `tool/product_touchpoints.json` را تغییر دهید
4. پس از ادغام، بررسی‌ها را اجرا کنید:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
```
