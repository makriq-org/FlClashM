<div dir="rtl">

# 🛠 ساخت و نگه‌داری

[← README](../README.md) · [Русский](../../ru/docs/maintenance.md) · [English](../../en/docs/maintenance.md) · [中文](../../zh/docs/maintenance.md) · **فارسی**

فرمان‌های کار با مخزن و قراردادهایی که هنگام تغییر باید حفظ شوند. قواعد شاخه، کامیت و PR در [AGENTS.md](../../../AGENTS.md) است.

[ساخت](#build) · [معماری](#architecture) · [داده‌ها](#data) · [امنیت](#security) · [عیب‌یابی](#diagnostics) · [بالادست](#upstream) · [انتشار](#release)

<a id="build"></a>

## 🏗 ساخت و بررسی

محیط NixOS در `flake.nix` تعریف شده: Flutter 3.47.x، Go 1.27.2، JDK 17، SDK 37.0 و NDK 28.0.13004108/28.2.13676358. پیکربندی محیط را اعلانی تغییر دهید.

<div dir="ltr">

```bash
nix develop -c make dev
nix develop -c make check
nix develop -c make go-check
```

</div>

`make check` مرز product/base، GitHub Actions، تداوم انتشار، تست‌های `test/product`/`test/tool`، خطاهای کل `lib` (`analyze-app`) و تحلیل هدفمند را بررسی می‌کند. `make go-check`، vendor را آماده و gofmt را برای `core/backend` بررسی می‌کند؛ سپس vet، تست میزبان و تشخیص race را روی کل `core` با `GOFLAGS=-mod=vendor` اجرا می‌کند؛ کامپایلر C لازم است. APK: `build/app/outputs/flutter-apk/app-debug.apk`.

<details>
<summary>بدون Nix و نصب آزمایشی جدا</summary>

<div dir="ltr">

```bash
flutter pub get
dart setup.dart android --arch arm64 --out core
flutter build apk --debug --target-platform android-arm64
```

</div>

برای نصب تشخیصی مستقل، `ORG_GRADLE_PROJECT_backendDiagnostic=true` را پیش از `flutter build apk --debug --target-platform android-arm64` بگذارید. بسته: `com.makriq.flclash.backendcheck`؛ گزینهٔ اجرای دستی CI به نام `backend_test` از `.backendtest` استفاده می‌کند. به‌روزرسانی با حفظ داده: `adb install -r -t`.

برای ساخت محلی ساده‌شدهٔ گونهٔ آزمایشی، پس از آماده‌سازی هسته و منابع، `ORG_GRADLE_PROJECT_backendTest=true flutter build apk --release --target-platform android-arm64` را اجرا کنید؛ بسته: `com.makriq.flclash.backendtest`. CI همچنین `--dart-define=APP_ENV=pre` و `--dart-define=CORE_VERSION` را با مقدار برگرفته از `lib/core_version.dart` ارسال می‌کند.

</details>

CI شامل Go host/race، Dart/Flutter، تست واحد Kotlin، ساخت ARM64/armeabi-v7a و E2E در x86_64 با mihomo، validator، ByeDPI و TUN واقعی است. تغییرات صرفاً مستندات، از کارهای سنگین صرف‌نظر می‌کنند. تغییر پل Dart میان UI و backend، آزمون E2E با activity واقعی Flutter را اجرا می‌کند؛ خطای instrumentation یا استثنای مدیریت‌نشدهٔ Flutter باعث شکست بررسی می‌شود. شبیه‌ساز جای دستگاه ARM واقعی را نمی‌گیرد: پیش از انتشار، حالت‌ها، نودها، اشتراک‌ها، مرگ UI/`:remote`، حفظ Stop هنگام بازیابی، تعویض شبکه و مصرف باتری را بررسی کنید. موارد باز در [#132](https://github.com/makriq-org/FlClashM/issues/132) هستند. گردش‌کار `secret-scan` کامیت‌های PR و push را با Gitleaks بررسی می‌کند.

<a id="architecture"></a>

## 🧭 معماری

<div dir="ltr">

```text
RawProfile + Settings + Capabilities
  → Go Compiler + SecurityPolicy
  → immutable RuntimePlan
  → RuntimeCoordinator
  → mihomo / external processes / Android VPN
```

</div>

Flutter مسئول نمایش و پیش‌نویس است، فرمان می‌فرستد و عکس فوری می‌خواند. `core/backend/**` مالک پروفایل‌ها، تنظیمات، اشتراک‌ها، کامپایل و بازیابی است؛ بستهٔ قابل‌حمل بدون Android تست می‌شود. `core/backend_host.go`، mihomo و فرایندهای مستقل انتقال را متصل می‌کند. Android مجوزها، سرویس پیش‌زمینه، VPN/TUN، DNS و رویدادهای سیستم را فراهم می‌کند.

RuntimeCoordinator تنها مالک وضعیت تغییرپذیر اجراست. backend مستقل از Flutter در `:remote` اجرا می‌شود؛ `:validator` تجزیه‌گر mihomo را جدا می‌کند. `ui.attach` می‌تواند نودهای عادی را از پیش بدون VPN آماده کند. Stop پیش از اثرات ذخیره می‌شود، آماده‌سازی را لغو و VPN را خاموش می‌کند؛ نودهای آماده ممکن است برای تست تأخیر با UI باز باقی بمانند. بازیابی بدون UI پس از Stop آن‌ها را اجرا نمی‌کند؛ reset و Close همه را متوقف می‌کنند.

هنگام تغییر نمونهٔ backend یا بازیابی اتصال Binder، رابط زنده `ui.attach` را با `operationId` تازه و `restore: true` تکرار می‌کند. Go حضور UI و آماده‌سازی نودها را بدون اجرای دوبارهٔ `autoRun` بازیابی می‌کند؛ نیت توقف پس از Stop صریح حفظ می‌شود. بدون `restore`، نخستین بازکردن از سیاست معمول `autoRun` استفاده می‌کند.

کد پایه از طریق `tool/product_touchpoints.json` به `lib/product/**` دسترسی دارد؛ ابزارک‌ها در `allowedProductUi` ثبت می‌شوند. صفحه‌های فعال را در `lib/views/**` نگه دارید و در product تکرار نکنید؛ توسعهٔ آن‌ها مطابق معماری FlClashM با رعایت guards و allowlist و ثبت ارتباط با product در touchpoints مجاز است. تغییرات پایهٔ تحت بررسی در `tool/base_drift_allowlist.json` دلیل می‌خواهند؛ touchpoint جایگزین آن ثبت نیست. هماهنگی یا SharedPreferences قدیمی را به‌عنوان مرجع وضعیت به Dart/Kotlin برنگردانید.

<details>
<summary>قراردادهای backend هنگام تغییر اجرا</summary>

**Desired** نیت ذخیره‌شده، **Applied** آخرین نقشهٔ تأییدشده و **Observed** مشاهدهٔ واقعی است که اگر تأیید وضعیت ممکن نباشد، unknown است. RuntimePlan تغییرناپذیر با نسخه و SHA-256 بررسی می‌شود. آماده‌سازی از صف اثرات جداست؛ context و نسل، نتیجهٔ دیررس را مهار می‌کنند. شکست، نقشهٔ تأییدشده را برمی‌گرداند یا منابع را متوقف می‌کند. لغو VPN، Stop را ذخیره می‌کند و به Start صریح تازه نیاز دارد. صف به 8 فرمان پذیرفته‌شده محدود است و ظرفیت ذخیره‌ای برای Stop دارد.

API، داده و نقشه نسخه‌های مستقل دارند که اکنون `1` است. درخواست: `apiVersion`، `operationId`، `method`، `params`؛ پاسخ: `result` یا `error`. تکرار ID با محتوای یکسان نتیجهٔ پیشین را می‌دهد و با محتوای متفاوت رد می‌شود. هم نتیجهٔ عملیات دامنه و هم `runtimeOperationId` مرتبط را انتظار بکشید. timeout یا مرگ UI کار را لغو نمی‌کند؛ لغو صریح است.

متدهای اصلی: `snapshot`، `runtime.view`، `presentation`، `runtime.*`، `operation.get/cancel`، `settings.patch`، `profile.*`، `subscription.refresh`، `proxy.select`، `backup.export/restore`، `blob.*`، `engine.command`، `ui.attach`، `data.reset`. رویدادها `instanceId`/sequence دارند؛ سرریز به resync نیاز دارد. UI پیش از خواندن عکس فوری مشترک می‌شود و انتخاب اعمال‌شده را از `runtime.view` نشان می‌دهد. مشترک کند VPN را مسدود نمی‌کند.

</details>

<a id="data"></a>

## 💾 یکپارچگی داده‌ها

`backend-v1.json` نیت اجرا، نسل، input/plan تأییدشده و رسیدهای اجرا را نگه می‌دارد؛ `application-v1.json` ژورنال عملیات دامنه (تا 2 MiB) و `profiles.json` فهرست پروفایل و تنظیمات را ذخیره می‌کنند. نوشتن هر 3 فایل با atomic rename و fsync انجام می‌شود. بازیابی از آخرین ورودی تأییدشده استفاده می‌کند؛ عملیات ناتمام interrupted می‌شوند. revision جلوی نوشتن دیررس اشتراک/ویرایشگر را می‌گیرد. مهاجرت یک‌باره ID، تاریخ، بایت اصلی، فیلد ناشناخته و اعداد بزرگ را حفظ می‌کند.

ZIP شامل `config.json`، پروفایل‌های اصلی و کش provider است. منبع مفقود با فایل خالی جایگزین نمی‌شود. عبور از مسیر، symlink و zip-bomb رد می‌شوند. انتقال Binder: بلوک 192 KiB، تا 128 MiB هر فایل، 32 انتقال ناتمام و مجموع 512 MiB. حذف آخرین پروفایل Stop را ذخیره می‌کند؛ reset کار را متوقف و نشان مهاجرت و نسل‌های افزایشی را حفظ می‌کند.

Go اشتراک‌ها و فهرست برنامه‌ها را بدون UI به‌روز و در خطای شبکه کش قبلی را حفظ می‌کند. اعلان انقضای اشتراک در 3/2/1/0 روز و پس از انقضا نمایش داده می‌شود؛ Go جلوگیری از تکرار را ذخیره و Android نمایش را بومی می‌کند.

<a id="security"></a>

## 🔒 مرزهای امنیت

host قابل‌اعتماد مسیر فایل اجرایی، پوشهٔ برنامه، ABI، گواهی‌ها و پورت‌های محلی را تعیین می‌کند. پورت اشغال‌شدهٔ نود پیش از اجرا رد می‌شود. آرگومان‌ها بدون shell ارسال می‌شوند، SOCKS روی loopback گوش می‌دهد و Linux/Android فرزندان را با مرگ میزبان متوقف می‌کنند. بسته‌های عادی، dev و آزمایشی از VPN مستثنا و دارای بازهٔ پورت جدا هستند. Go SecurityPolicy پیش از بررسی و تثبیت نقشه اجرا می‌شود. انتخاب VPN کاربر حفظ می‌شود؛ `androidsecure` فقط mixed-port را می‌بندد.

JS در Goja بدون host bindings و با deadline/cancel اجرا می‌شود. محدودیت فهرست عمومی و بررسی در [تنظیم پروفایل](profiles.md#checks) است؛ سرور خصوصی اشتراک و فهرست برنامه مجاز است. کنترل‌کنندهٔ HTTP پیش از فرمان secret را بررسی می‌کند؛ مسیر دلخواه config، ارتقا و setter قدیمی مسدود است. DocumentsProvider ژورنال داخلی یا فایل اجرایی را منتشر نمی‌کند.

<a id="diagnostics"></a>

## 🩺 عیب‌یابی

دورسنجی وجود ندارد. دکمهٔ خروجی در صفحهٔ لاگ، ZIP لاگ Dart، Android، mihomo و نودها را با `manifest.json` (نسخه‌ها، Android API/ABI، زمان و حداقل وضعیت) می‌سازد. پروفایل، اشتراک، config و IPC payload وارد نمی‌شوند. اسرار، اعتبارنامه، URL اشتراک و نام پروفایل پیش از ثبت و دوباره هنگام خروجی پاک می‌شوند.

صف و چرخش، نوشتن را محدود می‌کنند؛ لاگ کند مانع توقف نود نمی‌شود. Android هر خط را به 16 KiB و Go به 4 KiB با صف 16خطی محدود می‌کند. mihomo بدون listener در Flutter هم ثبت می‌کند. خروجی بدون `:remote` نیز کار می‌کند؛ ZIP دارای `schemaVersion` است و پاک‌سازی با بردار تست مشترک Dart/Kotlin بررسی می‌شود.

<a id="upstream"></a>

## 🔄 به‌روزرسانی بالادست و نودها

معماری و قابلیت اطمینان backend مستقل Go بر کمینه‌کردن اختلاف با بالادست اولویت دارد. اصلاحات و قابلیت‌ها را گزینشی منتقل کنید؛ ادغام کامل را پس از ارزیابی سود، تعارض‌ها و اثر بر runtime انتخاب کنید. مرزهای Flutter ↔ backend و base ↔ product حفظ می‌شوند.

از شاخهٔ هدف فورک شاخهٔ کاری بسازید. پس از fetch، مرجع بالادست (شاخه یا برچسب) را صریحاً انتخاب و SHA کامل آن را در شرح کار یا PR ثبت کنید؛ سپس تغییرات منتخب را منتقل کنید یا با دلیل آن SHA را ادغام کنید. نام بستهٔ Dart ما `flclashx` است؛ نام بستهٔ بالادست (مثلاً `fl_clash`) را بررسی و در صورت نیاز importها و تولید کد را تطبیق دهید.

بلافاصله با `dart tool/check_base_drift.dart --upstream-ref=<upstream-sha>` اختلاف را نسبت به SHA منتخب بررسی کنید. می‌توان نیای مشترک را نیز با `--merge-base=<sha>` یا `BASE_DRIFT_MERGE_BASE` مشخص کرد. guards، touchpoints و allowlist همچنان الزامی‌اند: مسیرهای جدید base تحت بررسی به دلیل در allowlist نیاز دارند و ارتباط با product به ثبت touchpoint هم نیاز دارد. در حال حاضر `make check` و CI به‌طور پیش‌فرض اختلاف را نسبت به `upstream/dev` بررسی می‌کنند؛ بررسی SHA منتخب جایگزین آن‌ها نیست. تغییر مبنا یا قواعد CI به پیاده‌سازی جداگانه نیاز دارد. تغییرات runtime ابتدا با `-preN` و بررسی روی Android واقعی منتشر می‌شوند.

<div dir="ltr">

```bash
git fetch upstream
git fetch origin
nix develop -c make check go-check
```

</div>

`tool/prepare_core.sh` پوشهٔ `core/vendor` را از نو می‌سازد، patchها را بدون fuzz اعمال و رگرسیون Mieru را بررسی می‌کند. ساخت از `-mod=vendor` استفاده می‌کند و کش مشترک ماژول را تغییر نمی‌دهد. patchها برای درگاه فرمان HTTP backend و همگام‌سازی دسترسی DNS سیستم‌اند. اصلاح timeout QUIC بستهٔ Mieru وارد بالادست شده و آزمون رگرسیون آن حفظ شده است. در هر ارتقا بررسی‌شان کنید؛ patch اصلاح‌شده در بالادست و فراخوانی‌اش را حذف و vendor را برای بقیه حفظ کنید.

نسخه، کامیت منبع، ABI و SHA-256 نودها در `lib/product/runtime/*_release.dart` تثبیت شده‌اند؛ وابستگی‌ها در [tool/runtime_go_modules](../../../tool/runtime_go_modules/README.md) و یادداشت ساخت در [منابع](../../../assets/runtimes/) هستند. ارتقا و بازگشت باید pin، وابستگی و باینری را با هم تغییر دهند؛ سپس ABIهای انتشار را دوباره بسازید و بررسی کنید.

<a id="olcrtc-audit"></a>

<details>
<summary>OlcRTC: منبع، ساخت و محدودیت‌ها</summary>

- از `ghostlane-project/olcrtc`، شاخهٔ `proofkit`، نسخهٔ v0.12.1 و کامیت `b2c4b17ee35bfe65330aa9141f94dac082228bb2` استفاده می‌شود؛ منابع بدون وصلهٔ محلی ساخته می‌شوند
- نسخهٔ v0.12.1 تداخل RTP payload type در اتصال و مذاکرهٔ مجدد VK Calls را رفع می‌کند؛ وابستگی‌ها و قالب پیکربندی حفظ شده‌اند
- ارائه‌دهندگان جدید: `vkcalls` با `vp8channel` یا `videochannel`، `mtslink` با `vp8channel` و `salutejazz` و `max` با `datachannel`. برای `max`، فیلد `provider-token` الزامی و برای ورود مهمان `vkcalls` توکن غیرخالی ممنوع است. موتورهای جدید از طریق ارائه‌دهنده انتخاب می‌شوند، چون به اعتبارنامه‌های اضافی نیاز دارند که در قرارداد مستقیم `engine-url`/`engine-token` وجود ندارد
- تنظیمات جدید UDP/direct/failover/DTLS در Ghostlane در پروفایل FlClashM عرضه نمی‌شوند؛ CNC، SOCKS روی loopback، مالکیت انحصاری runtime در Go و مسیریابی موجود Mihomo حفظ می‌شوند
- وابستگی‌ها با به‌روزرسانی‌های امنیتی FlClashM در `tool/runtime_go_modules/olcrtc.mod/.sum` باقی می‌مانند؛ `covert-dtls` با نسخهٔ تثبیت‌شده افزوده شده است، اما پروفایل استتار آن فعال نمی‌شود
- با تغییر مخزن منبع، setup پیش از fetch، مقدار `origin` کش موجود را به‌روز می‌کند؛ `-buildvcs=false` وابستگی SHA به تگ‌های Git و عمق تاریخچه را حذف می‌کند. دستور CLI با `-version` مقدار `(devel)` را نشان می‌دهد؛ منبع دقیق در مُهر انتشار و فرادادهٔ منابع ثبت می‌شود

برای بازسازی OlcRTC، توزیع رسمی و بدون وصلهٔ Go 1.27.3 و NDK 28.0.13004108 لازم است.
`nix develop`، Go رسمی را از طریق `FLCLASHM_OLCRTC_GO` فراهم می‌کند؛ بیرون از این محیط،
اگر فایل رسمی `go` در `PATH` نیست، این متغیر را روی مسیر آن تنظیم کنید.
آماده‌سازی، وصله‌های nixpkgs در `net`/`mime` را رد می‌کند، زیرا مسیرهای store را جاسازی و SHA-256 را تغییر می‌دهند.
خود آرشیو رسمی می‌تواند در Nix store باشد. مُهر شامل `toolchain:official` و `buildid=none` است؛
BuildID غیرفعال است، چون Go حتی با `-trimpath` مسیر کامپایلر C را در آن قرار می‌دهد.
SHA-256 بایت‌های محصول هر ABI را تثبیت می‌کند.

این به‌روزرسانی OLC2، handshake v3 و OLVC 5 را حفظ می‌کند. یکسان‌بودن نسخهٔ قالب،
جای آزمایش سرور قدیمی با کلاینت جدید از طریق سرویس موردنیاز را نمی‌گیرد.
سرویس‌های جدید به پشتیبانی سرور نیاز دارند. پیش از انتشار، شروع سرد، اتصال مجدد و VPN را
روی ABIهای فیزیکی اندروید بررسی کنید؛ [یادداشت‌های ممیزی و بررسی](#olcrtc-audit) را ببینید.

طبق تصمیم پذیرفته‌شده، منابع Ghostlane بدون اصلاح یافته‌های ممیزی ادغام شده‌اند.
مشکلات شناخته‌شده عبارت‌اند از تغییر جریان مرتب‌شدهٔ SEI بدون احراز اصالت، پیمایش نامحدود `floor`،
انباشت رکوردهای حسابداری نشست در سرور و نبود الزام اتصال `/stats` به loopback.
دو مورد آخر به حالت `srv` مربوط‌اند که برنامه آن را اجرا نمی‌کند. دست‌کاری محتوای رمز‌شده
و حمله از طریق SFU زنده در ممیزی تأیید نشده‌اند. به‌روزرسانی وابستگی‌ها یا ساخت موفق
به‌معنای رفع این محدودیت‌ها نیست.

OlcRTC با Go 1.27.3 رسمی بازسازی شده تا
[GO-2026-6809](https://pkg.go.dev/vuln/GO-2026-6809) در اعتبارسنجی گواهی رفع شود.
گراف وابستگی‌های شخص ثالث تغییر نکرده است. این به‌روزرسانی یافته‌های ممیزی Ghostlane
را که در بالا آمده‌اند رفع نمی‌کند.

بررسی به‌روزرسانی v0.12.1: تست‌های VK Calls، شامل تداخل payload type و مذاکرهٔ مجدد،
تست‌های config/client/protect و E2E محلی با `-race` و وابستگی‌های تثبیت‌شدهٔ FlClashM موفق بودند.
سه ABI اندروید بازسازی شدند؛ `setup.dart` با Go رسمی، SHA-256 را بازتولید کرد و اجرای بعدی از کش استفاده کرد.
در شبیه‌ساز Android 16، همان باینری دقیق x86_64، دستور `-version` را اجرا و پیکربندی CNC را تجزیه کرد
و به‌درستی رد اتصال به endpoint محلیِ غیرقابل‌دسترسی را گزارش داد.
اتصال زنده از طریق VK و مسیر کامل VPN برنامه برای این نسخه آزمایش نشده‌اند.

بررسی بازتولیدپذیری پس از بازبینی: Go رسمی از آرشیو و از flake، و NDK از آرشیو اصلی و از nixpkgs،
با `-buildid=` برای هر سه ABI فایل‌های یکسان در سطح بایت تولید کردند.
باینری‌ها مسیر `/nix/store/` ندارند؛ بررسی رد Go وصله‌شده پیش از شروع ساخت موفق است.

آزمایش زنده در 2026-10-22، روی کامیت قبلی `b8a6e12` و پیش از v0.12.1:
با `vkcalls + vp8channel`، سرور لینوکس و همان باینری دقیق x86_64 داخلی روی شبیه‌ساز Android 16
به اتاق واقعی VK پیوستند. از طریق SOCKS با حل نام راه‌دور، پاسخ HTTPS 200 از example.com،
Cloudflare و raw.githubusercontent.com دریافت شد؛ فایل 243,217 بایتی در 1.36 ثانیه منتقل شد
و بایت‌به‌بایت با دریافت مستقیم برابر بود، با SHA-256
`40d15ce858cf058cff92606001a29ee1689db88c121a2f0c283163a0d64a7375`.
اعتبارسنجی TLS غیرفعال نشد. اجرای نخست به DNS نوع fake-IP رایانهٔ آزمایش برخورد کرد؛
سرور به‌درستی نشانی‌های رزروشده را رد کرد. اجرای بعدی از پل محلی DNS-to-DoH به Cloudflare
استفاده کرد که نشانی‌های عمومی واقعی برمی‌گرداند؛ بررسی‌های ترافیک خروجی OlcRTC تغییر نکردند.
MTS به تصمیم کاربر از آزمایش زنده کنار گذاشته شد. این اجرا ترابری و فایل اجرایی اندروید را تأیید می‌کند،
اما مسیر کامل VPN برنامه، ABIهای فیزیکی ARM یا کارکرد در شبکه‌های دارای فهرست مجاز را تأیید نمی‌کند.
اتاق‌ها، کلیدها و توکن‌های آزمایش در مخزن ذخیره نمی‌شوند.

- **به‌روزرسانی:** کامیت تثبیت‌شده را عوض کنید، سه ABI اندروید را با Go 1.27.3 و NDK 28.0.13004108 تثبیت‌شده از طریق `dart setup.dart android --out runtime-assets` بازبسازید، SHA-256 تثبیت‌شده را بر اساس فایل‌های تولیدشده به‌روز کنید و فرمان و تست‌ها را دوباره اجرا کنید.
- **بازگردانی:** `openlibrecommunity/olcrtc@f3ad8fb7c0d0fa981423f83269526fa94077c23d` را همراه با فایل‌های قفل وابستگی، فرادادهٔ انتشار و محصولات اندروید بازگردانید. پروفایل سرویس‌های جدید دیگر پشتیبانی نمی‌شود؛ پروفایل‌های قبلی مهاجرت نمی‌خواهند.

</details>

<a id="release"></a>

## 📦 انتشار و بازگشت

نسخه در `pubspec.yaml`: قالب `MAJOR.MINOR.PATCH[-preN]+YYYYMMDDnn`. تغییر ناسازگار MAJOR، قابلیت MINOR و اصلاح PATCH می‌خواهد؛ اثر بالادست بر کاربر هم لحاظ می‌شود. `versionCode` هر tag باید اکیداً افزایش یابد. tag به‌شکل `v<versionName>` فقط روی کامیت ادغام‌شده در main قرار می‌گیرد؛ `applicationId` انتشار: `com.makriq.flclash`.

شاخهٔ `release/<version>` بسازید، موارد کاربرمحور Unreleased را به بخش CHANGELOG هم‌نام tag آینده منتقل، نسخه را به‌روز و بررسی‌ها را اجرا کنید. پس از PR/merge، tag بزنید و push کنید. CI امضای APK/AAB را بررسی و APK عمومی/ABI، AAB، SHA-256 و `FlClashM-android-release-metadata.json` را منتشر می‌کند. پیش‌انتشار فقط با فعال‌بودن تنظیم مربوط در برنامه دیده می‌شود.

SourceForge منبع اصلی و GitHub پشتیبان است. اشاره‌گرهای stable/pre زیر پیش از خواندن JSON با `.sig` و Ed25519 بررسی می‌شوند. SHA-256 هر APK و سپس امضای بسته در Android بررسی می‌شود. هدر ارائه‌دهنده بر اعتماد به به‌روزرسانی اثر ندارد.

فهرست منتشرشده `versionCode` کلی و برای هر APK، مقادیر `urls` (آینه‌ها به‌ترتیب)، `size` (بایت)، `sha256` و `versionCode` واقعی را ذخیره می‌کند. انتشار پایدار باید فایل‌های `.sha256` جداگانهٔ منابع را داشته باشد.

<div dir="ltr">

```text
https://flclashm.sourceforge.io/update/stable.json
https://flclashm.sourceforge.io/update/pre.json
```

</div>

<details>
<summary>انتشار و جلوگیری از تنزل</summary>

ابتدا فایل‌های `releases/<tag>`، سپس امضای اشاره‌گر و در پایان JSON را منتشر کنید. اسرار لازم: `APP_UPDATE_SIGNING_KEY`، `SOURCEFORGE_SSH_KEY`، `SOURCEFORGE_USERNAME`. کد APK با Android SDK استخراج می‌شود؛ Flutter در `--split-per-abi` فاصلهٔ ABI اضافه می‌کند. کد فهرست بیشترین کد واقعی APK است؛ GitHub همان کدهای metadata را به‌کار می‌برد.

بالاترین versionCode و زمان انتشار برای هر کانال جدا ذخیره می‌شود. فهرست امضاشدهٔ قدیمی رد و تنزل APK در Android مسدود می‌شود. بازگشت با انتشار اصلاحی تازه و کد بالاتر انجام می‌شود. برای تعویض کلید، ابتدا نسخهٔ واسط شامل کلید عمومی جدید منتشر کنید.

</details>

</div>
