# 🏗 معماری

FlClashM بر پایهٔ FlClashX ساخته شده است. منطق محصولِ fork از پایه جدا است تا به‌روزرسانی‌های upstream ویژگی‌های سفارشی را نشکنند.

## 🔗 خط لولهٔ اصلی

```
RawProfile → ProfileCompiler → SecurityPolicy → RuntimePlan → EngineManager → EngineAdapter
```

| مرحله | چه می‌کند |
|-------|-----------|
| **RawProfile** | پروفایل خام همان‌طور که هست |
| **ProfileCompiler** | خواندن پروفایل، نرمال‌سازی تونل‌زنی جداگانه، کامپایل نودهای داخلی |
| **SecurityPolicy** | اجبار TUN روی اندروید |
| **RuntimePlan** | ساخت نقشهٔ راه‌اندازی محیط اجرا |
| **EngineManager** | مدیریت چرخهٔ حیات موتور |
| **EngineAdapter** | پل به `mihomo` |

## 🧱 لایه‌ها

1. 🎛 **پایهٔ FlClashX** — UI، ناوبری، مسیر پایهٔ runtime.
2. 📦 **لایهٔ محصول** (`lib/product/**`) — کامپایل پروفایل، امنیت، به‌روزرسانی، صفحات مخصوص fork.
3. ⚙️ **لایهٔ محیط اجرا** — `mihomo` (پایه) و نودهای داخلی `naiveproxy`، `olcrtc`، `byedpi`، `stormdns`.
4. 📱 **لایهٔ سکو** — VPN اندروید، سرویس پیش‌زمینه، نصب‌کننده، اعلان‌ها.

## 🚧 مرز base/product

<a id="base-product-boundary"></a>

کد پایهٔ بیرون از `lib/product/**` **فقط از طریق** نقاط اتصالِ `tool/product_touchpoints.json` به لایهٔ محصول دسترسی دارد.

- صفحات زندهٔ `lib/views/**` در `lib/product/**` **تکرار نمی‌شوند**: پایه صفحات upstream را با حداقل قلاب نگه می‌دارد.
- کلاس‌های Widget و کارخانه‌های `Widget` در `lib/product/**` به‌طور پیش‌فرض ممنوع‌اند؛ عناصر خاص FlClashM باید با ذکر دلیل به‌صراحت در `allowedProductUi` از `tool/product_touchpoints.json` ثبت شوند.

با یک گیت اجرا می‌شود:

```bash
dart tool/check_product_boundaries.dart
```

> 📎 ارتباط این با به‌روزرسانی upstream در [همگام‌سازی با FlClashX](upstream-sync.md). قواعد مشارکت‌کنندگان در [AGENTS.md](../../../../AGENTS.md).

## 🧩 سرویس‌های اصلی

| سرویس | مسئولِ |
|-------|--------|
| `ProfileCompiler` | خواندن و نرمال‌سازی پروفایل |
| `SecurityPolicy` | اجبار TUN روی اندروید |
| `EngineManager` | چرخهٔ حیات موتور |
| `BuiltInProxySupervisor` | چرخهٔ حیات نودهای داخلی |
| `AppUpdateService` | بررسی، دانلود و نصب به‌روزرسانی برنامه |
| `AppUpdateManifestVerifier` | بررسی امضا و قرارداد manifest به‌روزرسانی |
| `AccessControlService` | تونل‌زنی جداگانه |

---

> 🌍 زبان‌های دیگر: [Русский](../../../ru/docs/development/architecture.md) · [English](../../../en/docs/development/architecture.md) · [中文](../../../zh/docs/development/architecture.md)
