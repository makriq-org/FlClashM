# 🛠 مستندات توسعه‌دهنده

FlClashM چگونه ساخته شده و چطور با آن کار کنیم بی‌آنکه همگام‌سازی ارزان با upstream را خراب کنیم.

**اصل بنیادی:** منطق محصولِ fork در `lib/product/**` قرار دارد و از پایهٔ FlClashX جدا است. کد پایه فقط از طریق نقاط اتصال ثبت‌شده به آن دسترسی دارد. این کار به‌روزرسانی upstream را ارزان نگه می‌دارد و مانع حل‌شدن ویژگی‌های fork در پایه می‌شود.

---

## 📖 بخش‌ها

| بخش | دربارهٔ |
|-----|---------|
| 🏗 **[معماری](architecture.md)** | خط پردازش اصلی، لایه‌ها، مرز base/product، سرویس‌های اصلی |
| ⚙️ **[محیط اجرا](runtime.md)** | پردازش پروفایل، بررسی و چرخهٔ حیات نودهای داخلی، عکس فوری VPN |
| 🔒 **[امنیت](security.md)** | سیاست runtime، حفاظت‌های اندروید، مرزهای هدر ارائه‌دهنده |
| 📦 **[انتشار](release-contract.md)** | محتوای انتشار، خط لوله، تحویل امضاشدهٔ به‌روزرسانی، بازگردانی |
| 🔄 **[همگام‌سازی با FlClashX](upstream-sync.md)** | فرایند ارزان به‌روزرسانی پایه |
| ✅ **[بررسی بیلد](verification.md)** | گیت‌های محلی و CI |

---

## 🧰 فرمان‌های محلی (کوتاه)

روی NixOS کل محیط را `flake.nix` تعریف می‌کند:

```bash
nix develop -c make dev              # APK دیباگ (arm64)
nix develop -c make check            # boundaries + release-contract + drift + test + analyze
nix develop -c make fetch-upstream   # کشیدن upstream/dev
```

جزئیات ساخت و بررسی در [بررسی بیلد](verification.md) و [README پروژه](../../README.md#-ساخت).

> 🤖 قواعد کار روی کد (مرزهای base/product، touchpointها، بودجهٔ drift) در [AGENTS.md](../../../../AGENTS.md).

---

> 🌍 زبان‌های دیگر: [Русский](../../../ru/docs/development/README.md) · [English](../../../en/docs/development/README.md) · [中文](../../../zh/docs/development/README.md)
