// آدوان — Edge Function: فرم تماس و خبرنامه
// استقرار:  supabase functions deploy contact
// متغیرها:  TURNSTILE_SECRET (برای فعال‌سازی کپچا)
//
// نوشتن در جدول‌های messages / newsletter با کلید service_role انجام می‌شود،
// چون برای anon هیچ policy نوشتنی روی این جدول‌ها وجود ندارد.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TURNSTILE_SECRET = Deno.env.get("TURNSTILE_SECRET") ?? "";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json; charset=utf-8" },
  });

const clean = (v: unknown, max: number) =>
  String(v ?? "").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "").trim().slice(0, max);

async function verifyTurnstile(token: string, ip: string) {
  // کپچا فقط وقتی اجباری می‌شود که TURNSTILE_SECRET ست شده باشد
  if (!TURNSTILE_SECRET) return true;
  if (!token) return false;
  const body = new FormData();
  body.append("secret", TURNSTILE_SECRET);
  body.append("response", token);
  if (ip) body.append("remoteip", ip);
  try {
    const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      body,
    });
    const data = await res.json();
    return data?.success === true;
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SB_URL || !SERVICE_KEY) return json({ error: "server_not_configured" }, 500);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const type = clean(payload.type, 20) || "contact";
  const token = clean(payload.token, 4000);
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "";

  const captchaOk = await verifyTurnstile(token, ip);
  if (!captchaOk) return json({ error: "captcha_failed" }, 403);

  const db = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });

  if (type === "newsletter") {
    const email = clean(payload.email, 200).toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return json({ error: "invalid_email" }, 400);
    const { error } = await db.from("newsletter").upsert({ email }, { onConflict: "email" });
    if (error) return json({ error: "insert_failed", detail: error.message }, 500);
    return json({ ok: true });
  }

  const name = clean(payload.name, 120);
  const contact = clean(payload.contact, 200);
  const subject = clean(payload.subject, 200);
  const message = clean(payload.message, 4000);

  if (name.length < 2) return json({ error: "invalid_name" }, 400);
  if (contact.length < 3) return json({ error: "invalid_contact" }, 400);
  if (message.length < 3) return json({ error: "invalid_message" }, 400);

  // محدودیت ساده: حداکثر ۵ پیام از یک مخاطب در هر ساعت
  const hourAgo = new Date(Date.now() - 3600_000).toISOString();
  const { count } = await db
    .from("messages")
    .select("id", { count: "exact", head: true })
    .eq("contact", contact)
    .gte("created_at", hourAgo);
  if ((count ?? 0) >= 5) return json({ error: "rate_limited" }, 429);

  const { error } = await db.from("messages").insert({
    name,
    contact,
    subject: subject || null,
    message,
  });
  if (error) return json({ error: "insert_failed", detail: error.message }, 500);

  return json({ ok: true });
});
