# وب‌سایت آدوان | Advan Website

سایت ویترینی شرکت آدوان روی **Cloudflare Workers (Static Assets)** با بک‌اند **Supabase**.
بدون مرحلهٔ بیلد: فایل‌های داخل `public/` همان‌هایی هستند که سرو می‌شوند.

**زبان رابط:** فارسی و راست‌به‌چپ (RTL).

---

## 📦 ساختار پروژه

| مسیر | توضیح |
| --- | --- |
| `public/index.html` | کل سایت بازدیدکننده (HTML + CSS + JS داخلی، تک‌فایل) |
| `public/admin.html` | **پنل مدیریت** — محتوا، محصولات، بلاگ، سوالات، پیام‌ها، کاربران، تنظیمات |
| `public/supabase.js` | کتابخانهٔ Supabase (نسخهٔ محلی، از مسیر `/supabase.js` سرو می‌شود) |
| `public/robots.txt`, `public/sitemap.xml` | تنظیمات موتور جستجو |
| `supabase_setup.sql` | ساخت جدول‌ها، تریگرها، policyهای RLS و محتوای اولیه |
| `supabase/functions/contact/index.ts` | Edge Function فرم تماس/خبرنامه (بررسی Turnstile) |
| `wrangler.jsonc` | تنظیمات انتشار روی Cloudflare Workers |

## ✨ امکانات

- طراحی مینیمال با **حالت تیره/روشن** (تشخیص خودکار تم سیستم) و ۶ پالت رنگی، اندازهٔ فونت و کنترل انیمیشن — در مرورگر کاربر ذخیره می‌شود
- کاملاً ریسپانسیو، دسترسی‌پذیر (اسکیپ‌لینک، تلهٔ فوکوس، ARIA، `prefers-reduced-motion`)
- **چت‌بات فروش**، **جستجوی هوشمند** (`Ctrl+K`) و **توصیه‌گر محصول** — همه سمت مرورگر و بر پایهٔ محتوای دیتابیس
- **ورود/ثبت‌نام با Supabase Auth** + تأیید ایمیل با لینک یا کد شش‌رقمی
- **پنل مدیریت واحد** در `/admin.html`: ویرایش محتوا، محصولات، بلاگ و سوالات متداول؛ مدیریت پیام‌های فرم تماس و کاربران
- محتوای سایت در جدول `site_content` نگهداری می‌شود؛ ویرایش در پنل **بلافاصله برای همهٔ بازدیدکنندگان** اعمال می‌شود (نیازی به دانلود و جایگزینی فایل نیست)

## 🚀 راه‌اندازی اولیه (یک‌بار)

### ۱) دیتابیس

در Supabase → **SQL Editor → New query**، کل فایل `supabase_setup.sql` را اجرا کنید.
این فایل می‌سازد: `profiles` (با تریگر ساخت خودکار از `auth.users`)، `site_content`، `messages`، `newsletter` و policyهای RLS.

### ۲) حساب مدیر

۱. از خود سایت ثبت‌نام کنید و ایمیل را تأیید کنید.
۲. در SQL Editor اجرا کنید (ایمیل خودتان):

```sql
update public.profiles set role = 'admin' where email = 'you@example.com';
```

۳. اکنون `/admin.html` باز می‌شود. نقش‌های دیگر کاربران را هم از تب «کاربران» همان پنل تغییر دهید.

### ۳) Edge Function فرم تماس

بدون این مرحله، فرم تماس و خبرنامه پیام «ارسال ناموفق» می‌دهند (سایت بقیهٔ بخش‌ها را عادی نشان می‌دهد).

```bash
supabase functions deploy contact --project-ref lshfhxzppmoulmxdrrap
```

### ۴) Turnstile (کپچا) — اختیاری ولی توصیه‌شده

۱. در Cloudflare Dashboard → **Turnstile** یک widget برای دامنهٔ `adwan.ir` بسازید.
۲. **Site Key** را در `public/index.html` جای مقدار `TURNSTILE_SITEKEY` بگذارید:

```js
const TURNSTILE_SITEKEY='0x4AAAAAAA...';
```

۳. **Secret Key** را به‌عنوان راز تابع ثبت کنید:

```bash
supabase secrets set TURNSTILE_SECRET=0x4AAAAAAA...
```

> تا وقتی `TURNSTILE_SITEKEY` خالی است، کپچا رندر نمی‌شود و تابع هم بدون بررسی کپچا کار می‌کند.
> برای اجرای محلی تابع بدون کپچا، `ALLOW_WITHOUT_CAPTCHA=true` را ست کنید.

## ✏️ ویرایش محتوا

همهٔ محتوا (برند، هیرو، دربارهٔ ما، تماس، محصولات، بلاگ، سوالات متداول) از `/admin.html` ویرایش می‌شود و در جدول `site_content` ذخیره می‌شود. اگر ردیف `main` در دسترس نباشد (مثلاً Supabase قطع باشد)، سایت محتوای پیش‌فرض داخل `index.html` را نشان می‌دهد.

- **پشتیبان/بازیابی:** تب «تنظیمات» پنل، خروجی و ورودی JSON دارد.
- **مقادیر پیش‌فرض:** همان `DEFAULT_CONTENT` ابتدای اسکریپت `index.html` است.

## 🔐 امنیت

- نقش مدیر **سمت سرور** با RLS کنترل می‌شود: نوشتن در `site_content` و خواندن `messages`/`newsletter` فقط برای `is_admin()`.
- روی `messages` و `newsletter` هیچ دسترسی نوشتنی برای anon وجود ندارد؛ نوشتن فقط از Edge Function با کلید `service_role` انجام می‌شود (به‌همراه بررسی Turnstile و محدودیت ۵ پیام در ساعت).
- کلید `sb_publishable_...` داخل کد عمومی است و برای کلاینت طراحی شده؛ کلید `service_role` هرگز در پروژه قرار نمی‌گیرد.

## 🌍 انتشار

هر Push به `main` → **Cloudflare Workers Builds** خودکار منتشر می‌کند. دامنهٔ `adwan.ir` به‌صورت Custom Domain به Worker وصل است.

```bash
git add -A && git commit -m "update" && git push
```

فایل‌های `public/` بدون بیلد سرو می‌شوند؛ تغییری در `wrangler.jsonc` لازم نیست.

## 🧪 اجرای محلی

```bash
npx wrangler dev        # http://localhost:8787
```

گزینهٔ ساده‌تر: `public/` را با هر سرور استاتیک سرو کنید (مثلاً `npx serve public`). پنل مدیریت در `/admin.html` است.

## 📌 نکات

- فونت **وزیرمتن** از Google Fonts بارگذاری می‌شود؛ در صورت قطعی اینترنت، فونت سیستم جایگزین می‌شود.
- اطلاعات تماس، قیمت‌ها و آمار داخل سایت **دادهٔ نمونه** هستند و از پنل مدیریت قابل تغییرند.
- `public/admin.html` با `noindex` و مسدود در `robots.txt` است.
