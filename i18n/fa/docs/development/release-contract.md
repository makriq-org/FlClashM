# 📦 انتشار

## 🏷 قواعد نسخه

| | قالب |
|---|------|
| **نسخهٔ پایدار** | `MAJOR.MINOR.PATCH+versionCode` |
| **نسخهٔ پیش‌انتشار** | `MAJOR.MINOR.PATCH-preN+versionCode` |
| **تگ** | دقیقاً `v<versionName>` |
| **`applicationId`** | `com.makriq.flclash` |

`versionName` کامل، شامل `-preN`، در `pubspec.yaml` نگه‌داری می‌شود. CI هنگام ساخت آن
را بازنویسی نمی‌کند و تگ باید با افزودن پیشوند `v` دقیقاً با آن یکسان باشد.

## 📂 محتوای انتشار

- `FlClashM-android-universal.apk`
- `FlClashM-android-arm64-v8a.apk`
- `FlClashM-android-armeabi-v7a.apk`
- `FlClashM-android-x86_64.apk`
- `FlClashM-android-release.aab`

> 🔐 هر انتشار برای هر فایل یک `.sha256` دارد. برای انتشار پایدار، وجود آن‌ها افزون بر این **بخش الزامی** قرارداد انتشار شمرده می‌شود.

## 🚀 خط لوله

1. ✅ بررسی مرز محصول، انحراف upstream، تست‌ها و تحلیل
2. 🔁 بررسی پیوستگی انتشار
3. 🏗 ساخت محصولات
4. 🧾 بررسی امضای همهٔ APKها و AAB
5. 📝 تولید متادیتا
6. 🔢 تولید checksumها
7. ✍️ ساخت و امضای manifest به‌روزرسانی Ed25519
8. ☁️ انتشار APKها و manifest در SourceForge
9. 🐙 انتشار در GitHub

## 📥 تحویل به‌روزرسانی برنامه

SourceForge `flclashm` کانال **اصلی** تحویل APK است و GitHub **پشتیبان**. برنامه اشاره‌گرهای ثابت را می‌خواند:

- `https://flclashm.sourceforge.io/update/stable.json`
- `https://flclashm.sourceforge.io/update/pre.json`

کنار هر اشاره‌گر یک امضای دودویی `.sig` منتشر می‌شود. امضا **پیش از تجزیهٔ JSON** با کلید عمومی داخلی **Ed25519** بررسی می‌شود. manifest شامل SHA-256 و فهرست مرتب آینه‌ها برای هر APK بر پایهٔ ABI است. هدرهای ارائه‌دهنده برای تعیین اعتماد **استفاده نمی‌شوند**.

فایل‌های انتشار نخست به پوشهٔ تغییرناپذیر `releases/<tag>` بارگذاری می‌شوند. سپس امضای اشاره‌گر و **در پایان** خودِ اشاره‌گر منتشر می‌شود.

> 🔑 انتشار به رازهای `APP_UPDATE_SIGNING_KEY`، `SOURCEFORGE_SSH_KEY` و `SOURCEFORGE_USERNAME` نیاز دارد.

## ⏮ بازگردانی

برنامه بیشترین `versionCode` و زمان انتشار را **به‌تفکیک کانال** به یاد می‌سپارد و بازپخش یک manifest امضاشدهٔ قدیمی را رد می‌کند. بنابراین:

- بازگردانی **فقط با یک انتشار اصلاحیِ جدید** با `versionCode` بزرگ‌تر انجام می‌شود؛
- APK نصب‌شده را نیز نمی‌توان با اندروید پایین آورد؛
- هنگام تغییر کلید manifest، نخست یک نسخهٔ **گذارِ** برنامه با کلید عمومی جدید منتشر می‌شود.

---

> 🌍 زبان‌های دیگر: [Русский](../../../ru/docs/development/release-contract.md) · [English](../../../en/docs/development/release-contract.md) · [中文](../../../zh/docs/development/release-contract.md)
