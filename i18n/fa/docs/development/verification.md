# ✅ بررسی بیلد

## 🤖 بررسی CI

`.github/workflows/android-base-verification.yaml` این‌ها را بررسی می‌کند:

- 🚧 مرزهای لایهٔ محصول؛
- 📦 قرارداد انتشار؛
- 🔄 انحراف فایل‌های پایه نسبت به `upstream/dev`؛
- 🧪 تست‌های `test/product` و `test/tool`؛
- 🔍 تحلیل ایستای انتخابی کد محصول و انتشار؛
- 🏗 بیلد اندروید برای `arm64`.

> ➕ هنگام تغییر `android`، `core`، `assets/runtimes`، `setup.dart` یا `lib/product/runtime`، افزون بر این `armeabi-v7a` و `x86_64` نیز ساخته می‌شوند.

**چطور فعال می‌شود.** برای شاخه‌های کاری، جریان اصلی روی رویداد pull request اجرا می‌شود و `push` فقط برای `main` به کار می‌رود. جریان جداگانهٔ پیوستگی انتشار برای اجرای دستی نگه داشته شده: این بررسی به‌طور خودکار پیش‌تر بخشی از جریان اصلی است، پس یک کامیت مجموعه‌بررسی تکراری نمی‌سازد. اجرای جدید همان pull request، اجرای ناتمام پیشین را لغو می‌کند. اگر فقط مستندات نامرتبط تغییر کرده باشد، کارهای سنگین رد می‌شوند.

## 💻 بررسی محلی

```bash
flutter pub get
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
dart tool/check_base_drift.dart
flutter test test/product test/tool
flutter analyze --fatal-infos lib/product test/product test/tool
```

## 📱 بیلد اندروید

نیازمند: Android SDK، NDK `28.0.13004108`، JDK 17.

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --release
```

> ⚠️ بررسی کامل راه‌اندازی برنامه، VPN، سرویس‌های پس‌زمینه و نودهای داخلی روی **دستگاه‌های واقعی اندروید** محلی می‌ماند.

---

> 🌍 زبان‌های دیگر: [Русский](../../../ru/docs/development/verification.md) · [English](../../../en/docs/development/verification.md) · [中文](../../../zh/docs/development/verification.md)
