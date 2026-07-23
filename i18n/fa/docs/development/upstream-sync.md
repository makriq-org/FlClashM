# 🔄 همگام‌سازی با FlClashX

FlClashM بر پایهٔ FlClashX ساخته شده است. منطق محصول جدا شده تا به‌روزرسانی پایه **ارزان** بماند.

## 🧭 اصل

- 📦 منطق محصول در `lib/product/**` قرار دارد.
- 🚧 کد بیرون از `lib/product/**` فقط از طریق نقاط اتصال به آن دسترسی دارد.

> 📎 دربارهٔ مرز base/product بیشتر در [معماری](architecture.md#base-product-boundary).

## 📝 فرایند به‌روزرسانی

1. ⬇️ FlClashX را در شاخه‌ای جدا بکشید (به‌روزرسانی از `upstream/dev` انجام می‌شود).
2. 🧩 تعارض‌های `lib/product/**` را حل کنید.
3. 🎛 بیرون از `lib/product/**`، صفحات mount‌شده را در `lib/views/**` upstream نگه دارید؛ منطق محصول را فقط با حداقل قلاب پیوند بزنید.
   - اگر فایل پایه واقعاً `lib/product/**` را import کند — ورودی باید در `tool/product_touchpoints.json` باشد.
   - هر انحراف پایهٔ دیگر باید در `tool/base_drift_allowlist.json` توضیح داده شود.
4. ✅ پس از merge، بررسی‌ها را اجرا کنید:

```bash
dart tool/check_product_boundaries.dart
dart tool/check_release_continuity.dart
flutter test test/product
dart tool/check_base_drift.dart
```

> 🤖 فرایند کامل (fetch، `rerere`، بررسی‌کنندهٔ drift، گیت‌های نهایی) در بخش «فرایند به‌روزرسانی upstream» از [AGENTS.md](../../../../AGENTS.md) شرح داده شده.

---

> 🌍 زبان‌های دیگر: [Русский](../../../ru/docs/development/upstream-sync.md) · [English](../../../en/docs/development/upstream-sync.md) · [中文](../../../zh/docs/development/upstream-sync.md)
