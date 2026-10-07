-- ملحق: الدخول برقم الجوال + إيقاف الفترة التجريبية — نفّذه بعد الملفات 01 و02 و03 (مرة واحدة)
-- قبل التنفيذ في Supabase: Authentication ← Providers ← Phone ← Enable (وفعّل مزوّد رسائل SMS لرمز التحقق).

-- 1) الجوال في الأعضاء والدعوات (الصيغة الدولية مثل +966501234567)
alter table public.members add column if not exists phone text;
alter table public.invites add column if not exists phone text;
alter table public.invites alter column email drop not null;
alter table public.invites drop constraint if exists invites_contact_chk;
alter table public.invites add constraint invites_contact_chk check (email is not null or phone is not null);
create unique index if not exists invites_open_phone_uq on public.invites (org_id, phone) where accepted_at is null and phone is not null;

-- 2) إنشاء المكتب/العضو عند التسجيل: يطابق الدعوة بالجوال (أو بالبريد للحسابات القديمة)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv record; oid uuid; nm text; ph text;
begin
  ph := nullif(regexp_replace(coalesce(new.phone,''),'\D','','g'),'');          -- أرقام فقط: 966501234567
  nm := coalesce(nullif(new.raw_user_meta_data->>'full_name',''), case when ph is not null then '+'||ph end, split_part(new.email,'@',1));
  select * into inv from invites
   where accepted_at is null and (
         (ph is not null and regexp_replace(coalesce(phone,''),'\D','','g') = ph)
      or (new.email is not null and email is not null and lower(email) = lower(new.email)))
   order by created_at desc limit 1;
  if found then
    insert into members(org_id,user_id,role,full_name,email,phone)
      values (inv.org_id,new.id,inv.role,coalesce(nullif(inv.full_name,''),nm),new.email, case when ph is not null then '+'||ph end);
    update invites set accepted_at = now() where id = inv.id;
  else
    insert into organizations(name,created_by)
      values (coalesce(nullif(new.raw_user_meta_data->>'office_name',''),'مكتب جديد'), new.id)
      returning id into oid;
    insert into members(org_id,user_id,role,full_name,email,phone)
      values (oid,new.id,'owner',nm,new.email, case when ph is not null then '+'||ph end);
  end if;
  return new;
end $$;

-- 3) إيقاف الفترة التجريبية: مفتاح عام للفوترة (مطفأ حالياً = كل المكاتب تعمل بلا قيود اشتراك)
create table if not exists public.platform_settings (k text primary key, v jsonb not null);
alter table public.platform_settings enable row level security;
drop policy if exists ps_sel on public.platform_settings;
create policy ps_sel on public.platform_settings for select to authenticated using (true);
revoke insert, update, delete on public.platform_settings from authenticated;
insert into public.platform_settings(k,v) values ('billing_enforced','false'::jsonb) on conflict (k) do nothing;
-- لتفعيل الاشتراكات لاحقاً:  update public.platform_settings set v='true'::jsonb where k='billing_enforced';

create or replace function public.org_active(o uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from organizations where id = o) and (
    coalesce((select v = 'true'::jsonb from platform_settings where k='billing_enforced'), false) = false
    or exists(select 1 from organizations where id = o and (trial_ends_at > now() or coalesce(plan_ends_at,'-infinity') > now())))
$$;

-- المكاتب الجديدة بلا فترة تجريبية (تُحسب منتهية فور تفعيل الفوترة)
alter table public.organizations alter column plan set default 'standard';
alter table public.organizations alter column trial_ends_at set default now();
update public.organizations set plan = 'standard' where plan = 'trial';
