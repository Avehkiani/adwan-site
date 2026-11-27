-- ============================================================
--  آدوان — راه‌اندازی دیتابیس Supabase
--  یک‌بار در Supabase → SQL Editor اجرا کنید (New query → Run).
--  اجرای دوبارهٔ این فایل بی‌خطر است (idempotent).
-- ============================================================

-- ------------------------------------------------------------
-- ۱) پروفایل کاربران
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  email            text,
  full_name        text,
  role             text not null default 'user' check (role in ('user','admin')),
  created_at       timestamptz not null default now(),
  last_sign_in_at  timestamptz
);

alter table public.profiles enable row level security;

-- بررسی نقش مدیر بدون بازگشت بی‌پایان در policyها
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated, anon;

drop policy if exists "profiles read own or admin" on public.profiles;
create policy "profiles read own or admin"
  on public.profiles for select
  to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists "profiles admin update" on public.profiles;
create policy "profiles admin update"
  on public.profiles for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ساخت خودکار پروفایل برای هر کاربر تازه
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(coalesce(new.email,''), '@', 1)),
    'user'
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = case when coalesce(excluded.full_name,'') = '' then public.profiles.full_name else excluded.full_name end;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- پر کردن پروفایل کاربرانی که قبل از ساخت جدول ثبت‌نام کرده‌اند
insert into public.profiles (id, email, full_name, created_at, last_sign_in_at)
select u.id,
       u.email,
       coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), split_part(coalesce(u.email,''), '@', 1)),
       coalesce(u.created_at, now()),
       u.last_sign_in_at
from auth.users u
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- ۲) محتوای سایت (یک ردیف JSON با شناسهٔ 'main')
-- ------------------------------------------------------------
create table if not exists public.site_content (
  id          text primary key default 'main',
  data        jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null
);

alter table public.site_content enable row level security;

drop policy if exists "content public read" on public.site_content;
create policy "content public read"
  on public.site_content for select
  to anon, authenticated
  using (true);

drop policy if exists "content admin write" on public.site_content;
create policy "content admin write"
  on public.site_content for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ------------------------------------------------------------
-- ۳) پیام‌های فرم تماس
--    نوشتن فقط از طریق Edge Function «contact» با کلید service_role
--    انجام می‌شود؛ برای anon هیچ policy نوشتن وجود ندارد.
-- ------------------------------------------------------------
create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 2 and 120),
  contact     text not null check (char_length(contact) between 3 and 200),
  subject     text check (subject is null or char_length(subject) <= 200),
  message     text not null check (char_length(message) between 3 and 4000),
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);

create index if not exists messages_created_at_idx on public.messages (created_at desc);
create index if not exists messages_contact_idx on public.messages (contact, created_at desc);

alter table public.messages enable row level security;

drop policy if exists "messages admin all" on public.messages;
create policy "messages admin all"
  on public.messages for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ------------------------------------------------------------
-- ۴) خبرنامه
-- ------------------------------------------------------------
create table if not exists public.newsletter (
  email       text primary key check (char_length(email) <= 200),
  created_at  timestamptz not null default now()
);

alter table public.newsletter enable row level security;

drop policy if exists "newsletter admin read" on public.newsletter;
create policy "newsletter admin read"
  on public.newsletter for select
  to authenticated
  using (public.is_admin());

-- ------------------------------------------------------------
-- ۵) دسترسی‌های پایه
-- ------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select on public.site_content to anon, authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.site_content to authenticated;
grant select, insert, update, delete on public.messages to authenticated;
grant select on public.newsletter to authenticated;

-- ------------------------------------------------------------
-- ۶) تعیین مدیر
--    بعد از ساختن حساب از خود سایت، این خط را با ایمیل خودتان
--    یک‌بار اجرا کنید تا پنل مدیریت باز شود:
--
--    update public.profiles set role = 'admin' where email = 'you@example.com';
-- ------------------------------------------------------------

-- ============ محتوای اولیهٔ سایت ============
-- همان محتوای فعلی index.html؛ فقط اگر ردیف 'main' وجود نداشته باشد ساخته می‌شود.
insert into public.site_content (id, data)
values ('main', $json${"brand":{"name":"آدوان","latin":"ADWAN.IR","tagline":"مسیر شما به سوی آیندهٔ دیجیتال","blurb":"آدوان؛ همراه هوشمند کسب‌وکار شما در مسیر رشد دیجیتال."},"hero":{"badge":"نسل تازهٔ محصولات هوشمند آدوان معرفی شد","title":"آیندهٔ کسب‌وکار شما، <span class=\"grad-text\">یک مسیر هوشمند</span> است","lead":"از دستیارهای هوش مصنوعی تا زیرساخت ابری؛ آدوان ابزارهایی ساده، امن و مقیاس‌پذیر می‌سازد تا کسب‌وکار شما سریع‌تر رشد کند.","ctaA":"مشاهدهٔ محصولات","ctaB":"گفتگو با دستیار هوشمند"},"about":{"paras":["آدوان در سال ۱۳۹۷ با یک هدف ساده شروع شد: فناوری پیشرفته باید برای همهٔ کسب‌وکارها — از فروشگاه‌های کوچک تا سازمان‌های بزرگ — در دسترس و قابل فهم باشد. ما معتقدیم ابزار خوب، پیچیدگی را از مسیر شما برمی‌دارد، نه اینکه به آن اضافه کند.","امروز مجموعه‌ای از محصولات نرم‌افزاری، سرویس‌های ابری و راه‌حل‌های هوش مصنوعی ارائه می‌دهیم که روزانه هزاران کاربر به آن‌ها اعتماد می‌کنند. هر محصول با یک فلسفه طراحی شده: راه‌اندازی ساده، تجربه‌ای روان و پشتیبانی واقعی.","تیم ما از مهندسان، طراحان و متخصصان داده تشکیل شده که هر روز کنار مشتریان می‌نشینند تا مشکلات واقعی را بفهمند و برای آن‌ها راه‌حل بسازند."],"values":[{"icon":"zap","title":"سادگی","text":"طراحی‌هایی که نیازی به کتابچهٔ راهنما ندارند؛ هر چیزی همان‌جایی است که انتظارش را دارید."},{"icon":"shield","title":"اعتماد","text":"امنیت و پایداری دو خط قرمز ماست. دادهٔ شما با بالاترین استانداردها محافظت می‌شود."},{"icon":"sparkles","title":"هوشمندی","text":"هوش مصنوعی را جایی به کار می‌بریم که واقعاً ارزش می‌سازد؛ نه صرفاً در شعارها."}],"stats":[{"n":1200,"s":"+","l":"مشتری فعال"},{"n":98,"s":"٪","l":"نرخ رضایت"},{"n":7,"s":"","l":"سال تجربه"},{"n":24,"s":"/۷","l":"پشتیبانی شبانه‌روزی"}]},"products":[{"id":"hooshban","name":"هوش‌بان","cat":"هوش مصنوعی","icon":"sparkles","badge":"محبوب‌ترین","tagline":"مغز متفکر تیم پشتیبانی و فروش شما","desc":"دستیار هوش مصنوعی‌ای که با دانش سازمان شما آموزش می‌بیند؛ به سؤالات مشتریان در لحظه پاسخ می‌دهد، درخواست‌ها را ثبت می‌کند و تیم فروش را در هر مرحله همراهی می‌کند.","features":["آموزش با داده‌های اختصاصی شما","پاسخ‌گویی شبانه‌روزی بدون وقفه","اتصال به سایت، واتساپ و تلگرام","گزارش تحلیلی از مکالمات و نرخ تبدیل"],"price":"از ۴٬۹۰۰٬۰۰۰ تومان / ماه"},{"id":"sahab","name":"سحاب","cat":"ابری","icon":"cloud","badge":"جدید","tagline":"زیرساخت ابری، بدون دغدغهٔ نگه‌داری","desc":"سرورهای ابری سازمانی با راه‌اندازی چند دقیقه‌ای. منابع را هر لحظه که لازم داشتید کم یا زیاد کنید و فقط به اندازهٔ مصرف هزینه بدهید.","features":["راه‌اندازی سرور در کمتر از ۵ دقیقه","مقیاس‌پذیری خودکار منابع","بکاپ‌گیری روزانه با نگهداری ۳۰ روزه","مانیتورینگ لحظه‌ای و هشدار هوشمند"],"price":"از ۲٬۴۰۰٬۰۰۰ تومان / ماه"},{"id":"negah","name":"نگاه","cat":"نرم‌افزار","icon":"chart","badge":"","tagline":"تصمیم‌گیری با داده، نه با حدس","desc":"سامانه تحلیل داده و داشبورد هوشمندی که تمام اطلاعات کسب‌وکار شما را یک‌جا جمع می‌کند و مهم‌ترین رویدادها را پیش از شما می‌بیند.","features":["اتصال به تمام منابع داده و فروشگاه‌سازها","داشبورد بلادرنگ قابل شخصی‌سازی","هشدار هوشمند برای روندهای غیرعادی","گزارش‌ساز خودکار دوره‌ای"],"price":"از ۳٬۵۰۰٬۰۰۰ تومان / ماه"},{"id":"peyvand","name":"پیوند","cat":"نرم‌افزار","icon":"plug","badge":"","tagline":"همهٔ ابزارهای شما، هم‌زبان و هماهنگ","desc":"پلتفرم یکپارچه‌سازی و اتوماسیون که نرم‌افزارهای حسابداری، فروش و پشتیبانی شما را به هم وصل می‌کند و کارهای تکراری را خودکار می‌سازد.","features":["بیش از ۲۰۰ اتصال آماده","ساخت گردش‌کار بدون کدنویسی","وب‌هوک و API کامل","زمان‌بندی و اجرای خودکار"],"price":"از ۱٬۹۰۰٬۰۰۰ تومان / ماه"},{"id":"sepehr","name":"سپهر","cat":"امنیت","icon":"shield","badge":"","tagline":"نگهبانی شبانه‌روزی از داده‌های شما","desc":"سامانه امنیت و مانیتورینگ سازمانی که رویدادهای کلیدی زیرساخت شما را پایش می‌کند و پیش از آنکه خطا به بحران تبدیل شود، خبر می‌دهد.","features":["پایش مداوم آسیب‌پذیری‌ها","لاگ مرکزی رویدادهای امنیتی","هشدار فوری پیامکی و تلفنی","گزارش انطباق برای ممیزی‌ها"],"price":"از ۵٬۲۰۰٬۰۰۰ تومان / ماه"},{"id":"hub","name":"آدوان هاب","cat":"سخت‌افزار","icon":"cpu","badge":"پرفروش","tagline":"کنترل مرکزی فضای کار هوشمند شما","desc":"گجت هوشمندی که دستگاه‌های دفتر — از روشنایی و تهویه تا سیستم ورود — را یک‌جا مدیریت می‌کند؛ همه‌چیز از موبایل شما.","features":["اتصال هم‌زمان به بیش از ۱۰۰ دستگاه","کنترل کامل از اپلیکیشن موبایل","سازگار با پروتکل‌های رایج خانه هوشمند","نصب آسان بدون نیاز به سیم‌کشی"],"price":"۱۲٬۸۰۰٬۰۰۰ تومان"}],"blog":[{"id":"b1","title":"چگونه هوش مصنوعی هزینهٔ پشتیبانی مشتری را کاهش می‌دهد؟","cat":"هوش مصنوعی","date":"۱۴۰۴/۰۸/۱۲","mins":"۵ دقیقه مطالعه","icon":"sparkles","excerpt":"بخش بزرگی از مکالمات پشتیبانی سؤال‌های تکراری است. ببینید دستیار هوشمند چطور همین بخش را به یک فرصت رشد تبدیل می‌کند.","body":["بخش عمدهٔ زمان تیم‌های پشتیبانی صرف سؤال‌های تکراری می‌شود: وضعیت سفارش، ساعت کاری، شرایط بازگشت کالا و راهنمای اولیهٔ محصول. دستیار هوشمند دقیقاً همین لایه را برمی‌دارد؛ به مشتری در لحظه و بدون انتظار پاسخ می‌دهد و فقط موارد پیچیده را به کارشناس انسانی ارجاع می‌دهد.","در بسیاری از استقرارهای واقعی، همین تغییر ساده هزینهٔ هر تماس را به‌شکل محسوسی پایین می‌آورد و — مهم‌تر از آن — زمان پاسخ‌گویی را از ساعت‌ها به چند ثانیه می‌رساند. مشتری‌ای که سریع پاسخ بگیرد، دوباره برمی‌گردد.","نکتهٔ کلیدی، آموزش دستیار با دانش اختصاصی کسب‌وکار شماست: کاتالوگ محصولات، شرایط گارانتی و تاریخچهٔ مکالمات واقعی. یک دستیار عمومی خوب نیست؛ دستیاری که زبان سازمان شما را بلد باشد، خوب است."]},{"id":"b2","title":"راهنمای انتخاب زیرساخت ابری برای کسب‌وکار در حال رشد","cat":"ابری","date":"۱۴۰۴/۰۷/۲۵","mins":"۷ دقیقه مطالعه","icon":"cloud","excerpt":"پنج معیاری که قبل از خرید سرور ابری باید بررسی کنید؛ از مقیاس‌پذیری تا هزینهٔ خروج داده.","body":["اولین معیار، شناخت بار کاری خودتان است: وب‌سایت پرترافیک دارید یا پایگاه‌دادهٔ حساس؟ اپ واقعی‌محور یا فایل‌محور؟ هر بار کاری، ترکیب متفاوتی از پردازنده، حافظه و دیسک می‌خواهد و انتخاب اشتباه یعنی پرداخت بیشتر برای چیزی که استفاده نمی‌کنید.","معیار دوم مقیاس‌پذیری است. کسب‌وکار در حال رشد نباید هر شش ماه مهاجرت کند؛ زیرساخت باید بتواند منابع را بدون توقف سرویس افزایش دهد. سومین معیار، SLA و پشتیبانی واقعی است: ۹۹٫۹٪ روی کاغذ با ۹۹٫۹٪ در عمل تفاوت زیادی دارد.","دو معیار آخر را هم‌یشه فراموش می‌کنند: هزینهٔ خروج داده و بکاپ. بپرسید اگر روزی خواستید سرویس را عوض کنید، داده‌تان با چه هزینه‌ای بیرون می‌آید و آخرین نسخهٔ پشتیبان شما چند دقیقه قبل از حادثه است؟"]},{"id":"b3","title":"۱۰ عادت امنیتی که هر تیمی باید همین امروز شروع کند","cat":"امنیت","date":"۱۴۰۴/۰۶/۳۰","mins":"۴ دقیقه مطالعه","icon":"shield","excerpt":"امنیت با خرید ابزار گران شروع نمی‌شود؛ با ده عادت ساده و ارزان شروع می‌شود.","body":["۱. ورود دومرحله‌ای را برای همهٔ حساب‌های کاری اجباری کنید. ۲. مدیر هر سرویس را از مدیر کل جدا کنید. ۳. رمزها را با یک مدیر رمز نگه دارید، نه در فایل اکسل.","۴. دسترسی هر کارمند را محدود به بخش خودش کنید و موقع خروج، همان روز قطع کنید. ۵. به‌روزرسانی‌های امنیتی را از پیام‌های فوری سیستمی دنبال کنید، نه با تأخیر انسانی.","۶. لاگ رویدادها را جایی خارج از سرور اصلی نگه دارید. ۷. بکاپ را حداقل یک‌بار بازیابی آزمایشی کنید تا مطمئن شوید واقعاً کار می‌کند. ۸. یک صفحهٔ سادهٔ «اگر حساب‌مان هک شد چه کنیم» برای تیم بنویسید؛ در روز حادثه، این صفحه طلاست. ۹. لینک‌های مشکوک را با تمرین و شبیه‌سازی به تیم شناس بدهید. ۱۰. هر فصل یک‌بار لیست دسترسی‌ها را بازبینی کنید."]}],"faq":[{"q":"محصولات آدوان چگونه ارائه می‌شوند؟","a":"تمام محصولات نرم‌افزاری به‌صورت ابری (SaaS) ارائه می‌شوند؛ یعنی نیازی به نصب و نگه‌داری سرور نیست و به‌روزرسانی‌ها خودکار انجام می‌شود. تنها محصول سخت‌افزاری ما، آدوان هاب است که با پست به آدرس شما ارسال می‌شود."},{"q":"آیا امکان تست رایگان وجود دارد؟","a":"بله؛ هر محصول را می‌توانید ۱۴ روز رایگان و بدون نیاز به کارت بانکی تست کنید. در پایان دورهٔ تست، بدون هیچ تعهدی می‌توانید ادامه دهید یا انصراف بدهید."},{"q":"راه‌اندازی و استقرار چقدر طول می‌کشد؟","a":"محصولات ابری معمولاً در کمتر از یک ساعت فعال می‌شوند. برای پروژه‌های سازمانی با نیازهای سفارشی، تیم پیاده‌سازی ما معمولاً بین سه تا ده روز کاری کنار شماست."},{"q":"پشتیبانی چگونه انجام می‌شود؟","a":"پشتیبانی از طریق همین سایت، تلفن و ایمیل در ساعات اداری (شنبه تا پنجشنبه، ۹ تا ۱۸) پاسخ‌گوست و برای مشتریان قراردادهای سازمانی، پشتیبانی شبانه‌روزی با SLA مشخص ارائه می‌شود."},{"q":"آیا داده‌های ما امن است؟","a":"داده‌ها روی زیرساخت داخلی با رمزنگاری در حال انتقال و ذخیره‌سازی نگهداری می‌شوند، دسترسی کارکنان به لاگ ثبت می‌شود و بکاپ روزانه با نگهداری ۳۰ روزه گرفته می‌شود. گزارش امنیتی قرارداد برای مشتریان سازمانی در دسترس است."},{"q":"امکان قرارداد سازمانی و دریافت فاکتور رسمی هست؟","a":"بله؛ برای سازمان‌ها قرارداد سالانه با تعرفهٔ اختصاصی، فاکتور رسمی و امکان صورتحساب متنی صادر می‌شود. کافی است از بخش تماس درخواست بدهید تا کارشناس فروش با شما تماس بگیرد."}],"contact":{"address":"تهران، خیابان ولیعصر، برج فناوری آدوان، طبقهٔ ۹","phone":"۰۲۱-۹۱۰۰۸۸۰۰","phoneLink":"+982191008800","email":"hello@advan.ir","hours":"شنبه تا پنجشنبه، ۹ تا ۱۸"}}$json$::jsonb)
on conflict (id) do nothing;

