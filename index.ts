// يتحقق من الدفعة لدى Moyasar (من الخادم) ثم يفعّل اشتراك المكتب.
// النشر:  supabase functions deploy moyasar-verify
// الأسرار: supabase secrets set MOYASAR_SECRET_KEY=sk_test_xxx   (لا تضعه أبداً في ملف HTML)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: u } = await admin.auth.getUser(token);
    if (!u?.user) return json({ error: "غير مصرّح" }, 401);

    const { payment_id } = await req.json();
    if (!payment_id) return json({ error: "رقم الدفعة مفقود" }, 400);

    // المستخدم يجب أن يكون مدير مكتب
    const { data: mb } = await admin.from("members").select("org_id, role, status")
      .eq("user_id", u.user.id).maybeSingle();
    if (!mb || mb.status !== "active" || mb.role !== "owner") return json({ error: "الدفع متاح لمدير المكتب فقط" }, 403);

    // سبق تسجيلها؟ (منع إعادة الاستخدام)
    const { data: old } = await admin.from("payments").select("org_id").eq("moyasar_id", payment_id).maybeSingle();
    if (old) return json(old.org_id === mb.org_id ? { ok: true, already: true } : { error: "دفعة مستخدمة" },
      old.org_id === mb.org_id ? 200 : 409);

    // جلب الدفعة من Moyasar بالمفتاح السري
    const r = await fetch(`https://api.moyasar.com/v1/payments/${encodeURIComponent(payment_id)}`, {
      headers: { Authorization: "Basic " + btoa(Deno.env.get("MOYASAR_SECRET_KEY")! + ":") },
    });
    if (!r.ok) return json({ error: "تعذّر التحقق من الدفعة لدى Moyasar" }, 502);
    const p = await r.json();

    const planCode = p?.metadata?.plan, metaOrg = p?.metadata?.org_id;
    const { data: plan } = await admin.from("plans").select("*").eq("code", planCode).eq("active", true).maybeSingle();
    if (!plan) return json({ error: "خطة غير معروفة" }, 400);

    const expected = Math.round(Number(plan.amount_sar) * 100);
    if (p.status !== "paid") return json({ error: "الدفعة غير مكتملة: " + p.status }, 402);
    if (p.currency !== "SAR" || Number(p.amount) !== expected) return json({ error: "قيمة الدفعة لا تطابق الخطة" }, 400);
    if (metaOrg !== mb.org_id) return json({ error: "الدفعة لا تخص هذا المكتب" }, 403);

    const { error: pe } = await admin.from("payments").insert({
      org_id: mb.org_id, moyasar_id: payment_id, plan: plan.code, amount: p.amount, status: p.status,
    });
    if (pe) return json({ error: "دفعة مكررة" }, 409);

    // التمديد من نهاية الاشتراك الحالي إن كان ساري، وإلا من الآن
    const { data: org } = await admin.from("organizations").select("plan_ends_at").eq("id", mb.org_id).single();
    const start = org?.plan_ends_at && new Date(org.plan_ends_at) > new Date() ? new Date(org.plan_ends_at) : new Date();
    start.setMonth(start.getMonth() + plan.months);
    await admin.from("organizations").update({ plan: plan.code, plan_ends_at: start.toISOString() }).eq("id", mb.org_id);

    return json({ ok: true, plan: plan.code, plan_ends_at: start.toISOString() });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
