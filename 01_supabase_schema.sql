-- =====================================================================
--  نظام إدارة مكتب المحاماة — مخطط قاعدة بيانات Supabase (SaaS متعدد المكاتب)
--  نفّذ هذا الملف كاملاً مرة واحدة: Supabase → SQL Editor → New query → Run
--  قبل التنفيذ: Authentication → Providers → Email → فعّل "Confirm email"
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- 1) المكاتب ----------
create table if not exists public.organizations (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  vat_no        text,                       -- الرقم الضريبي (15 رقماً)
  cr_no         text,                       -- السجل التجاري
  phone         text,
  address       text,
  plan          text not null default 'trial',          -- trial | monthly | yearly
  trial_ends_at timestamptz not null default (now() + interval '14 days'),
  plan_ends_at  timestamptz,                             -- نهاية الاشتراك المدفوع
  role_perms    jsonb not null default '{
    "lawyer":   {"cases":"full","sessions":"full","finance":"read","crm":"full","hr":"none","staff":"read","admin":"read","other":"write","conf":true},
    "assistant":{"cases":"write","sessions":"write","finance":"none","crm":"write","hr":"none","staff":"read","admin":"none","other":"write","conf":false},
    "secretary":{"cases":"read","sessions":"write","finance":"none","crm":"read","hr":"none","staff":"read","admin":"none","other":"read","conf":false},
    "accountant":{"cases":"read","sessions":"none","finance":"full","crm":"read","hr":"write","staff":"read","admin":"none","other":"read","conf":false}
  }'::jsonb,
  created_at    timestamptz not null default now(),
  created_by    uuid
);

-- ---------- 2) الأعضاء والدعوات ----------
create table if not exists public.members (
  org_id     uuid not null references public.organizations(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('owner','lawyer','assistant','secretary','accountant')),
  status     text not null default 'active' check (status in ('active','suspended')),
  full_name  text,
  email      text,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id),
  unique (user_id)                           -- المستخدم ينتمي لمكتب واحد
);

create table if not exists public.invites (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  email       text not null,
  full_name   text,
  role        text not null check (role in ('lawyer','assistant','secretary','accountant')),
  invited_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  accepted_at timestamptz
);
create unique index if not exists invites_open_uq on public.invites (org_id, lower(email)) where accepted_at is null;

-- ---------- 3) بيانات النظام (سجلات JSON لكل مكتب) ----------
create table if not exists public.records (
  org_id     uuid not null references public.organizations(id) on delete cascade,
  t          text not null,                  -- اسم الوحدة: cases / invoices / hearings ...
  rid        text not null,                  -- معرّف السجل داخل الوحدة
  o          bigint not null default 0,      -- ترتيب العرض
  d          jsonb not null,                 -- محتوى السجل
  updated_by uuid,
  updated_at timestamptz not null default now(),
  primary key (org_id, t, rid)
);
create index if not exists records_org_t on public.records (org_id, t);

create table if not exists public.meta (       -- سجل الأحداث وقوالب المستندات
  org_id uuid not null references public.organizations(id) on delete cascade,
  k      text not null,
  v      jsonb not null,
  primary key (org_id, k)
);

create table if not exists public.files_meta ( -- مرفقات القضايا (الملف في Storage)
  id     bigint generated always as identity primary key,
  org_id uuid not null references public.organizations(id) on delete cascade,
  ca     text not null,
  name   text, type text, size bigint, da text,
  path   text not null
);
create index if not exists files_meta_ca on public.files_meta (org_id, ca);

-- ---------- 4) الاشتراكات والمدفوعات ----------
create table if not exists public.plans (
  code       text primary key,
  name       text not null,
  amount_sar numeric(10,2) not null,
  months     int not null,
  active     boolean not null default true
);
insert into public.plans(code,name,amount_sar,months) values
  ('monthly','اشتراك شهري',199,1),
  ('yearly','اشتراك سنوي',1990,12)
on conflict (code) do nothing;                  -- عدّل الأسعار من هنا حسب تسعيرك

create table if not exists public.payments (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations(id) on delete cascade,
  moyasar_id text not null unique,
  plan       text not null,
  amount     int  not null,                    -- بالهللة
  status     text not null,
  created_at timestamptz not null default now()
);

-- ---------- 5) تجميع الوحدات في مجموعات صلاحيات ----------
create table if not exists public.module_groups (t text primary key, grp text not null);
insert into public.module_groups(t,grp) values
  ('cases','cases'),
  ('judgments','cases'),
  ('memos','cases'),
  ('executive','cases'),
  ('admin','cases'),
  ('agencies','cases'),
  ('estates','cases'),
  ('trans','cases'),
  ('projects','cases'),
  ('contracts','cases'),
  ('archives','cases'),
  ('borrow','cases'),
  ('notices','cases'),
  ('letters','cases'),
  ('consultations','cases'),
  ('lc','cases'),
  ('lct','cases'),
  ('hearings','sessions'),
  ('appointments','sessions'),
  ('events','sessions'),
  ('meetings','sessions'),
  ('tasks','sessions'),
  ('discussions','sessions'),
  ('invoices','finance'),
  ('quotes','finance'),
  ('expenses','finance'),
  ('vendors','finance'),
  ('je','finance'),
  ('coa','finance'),
  ('acc','finance'),
  ('trust','finance'),
  ('time','finance'),
  ('assets','finance'),
  ('parties','crm'),
  ('leads','crm'),
  ('interactions','crm'),
  ('creq','crm'),
  ('recruit','hr'),
  ('attend','hr'),
  ('leaves','hr'),
  ('payroll','hr'),
  ('advances','hr'),
  ('appraisal','hr'),
  ('hr','staff'),
  ('circulars','admin')
on conflict (t) do update set grp = excluded.grp;
-- أي وحدة غير مذكورة تُعامل كمجموعة "other"

-- ---------- 6) دوال مساعدة (SECURITY DEFINER لتجنب التكرار في RLS) ----------
create or replace function public.org_active(o uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from organizations
                where id = o and (trial_ends_at > now() or coalesce(plan_ends_at,'-infinity') > now()))
$$;

create or replace function public.is_owner(o uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from members where org_id=o and user_id=auth.uid() and role='owner' and status='active')
$$;

create or replace function public.is_member(o uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from members where org_id=o and user_id=auth.uid() and status='active')
$$;

-- مستوى الصلاحية: 0 لا شيء، 1 عرض، 2 إضافة/تعديل، 3 كامل (مع الحذف)
create or replace function public.perm_level(o uuid, tbl text) returns int
language sql stable security definer set search_path = public as $$
  select case when m.role='owner' then 3 else coalesce(
           case org.role_perms -> m.role ->> coalesce(g.grp,'other')
             when 'full' then 3 when 'write' then 2 when 'read' then 1 else 0 end, 0) end
  from members m
  join organizations org on org.id = m.org_id
  left join module_groups g on g.t = tbl
  where m.org_id = o and m.user_id = auth.uid() and m.status = 'active'
$$;

create or replace function public.has_conf(o uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(bool_or(m.role='owner' or coalesce((org.role_perms -> m.role ->> 'conf')::boolean,false)), false)
  from members m join organizations org on org.id=m.org_id
  where m.org_id=o and m.user_id=auth.uid() and m.status='active'
$$;

-- هل السجل سرّي (قضية سرية) أو تابع لقضية سرية؟ (سجلات المالية مستثناة ليبقى المحاسب يرى الفواتير)
create or replace function public.conf_hidden(o uuid, tbl text, doc jsonb) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when tbl = 'cases' then coalesce(doc->>'conf','0') in ('1','نعم','true')
    when coalesce((select grp from module_groups where t=tbl),'other') = 'finance' then false
    when doc ? 'ca' and coalesce(doc->>'ca','') <> '' then exists(
       select 1 from records c where c.org_id=o and c.t='cases' and c.rid = doc->>'ca'
         and coalesce(c.d->>'conf','0') in ('1','نعم','true'))
    else false end
$$;

-- ---------- 7) إنشاء المكتب/العضو تلقائياً عند التسجيل ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv record; oid uuid; nm text;
begin
  nm := coalesce(nullif(new.raw_user_meta_data->>'full_name',''), split_part(new.email,'@',1));
  select * into inv from invites where lower(email)=lower(new.email) and accepted_at is null
    order by created_at desc limit 1;
  if found then
    insert into members(org_id,user_id,role,full_name,email)
      values (inv.org_id,new.id,inv.role,coalesce(nullif(inv.full_name,''),nm),new.email);
    update invites set accepted_at = now() where id = inv.id;
  else
    insert into organizations(name,created_by)
      values (coalesce(nullif(new.raw_user_meta_data->>'office_name',''),'مكتب جديد'), new.id)
      returning id into oid;
    insert into members(org_id,user_id,role,full_name,email) values (oid,new.id,'owner',nm,new.email);
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 8) سياسات الأمان (RLS): كل مكتب يرى بياناته فقط ----------
alter table public.organizations enable row level security;
alter table public.members       enable row level security;
alter table public.invites       enable row level security;
alter table public.records       enable row level security;
alter table public.meta          enable row level security;
alter table public.files_meta    enable row level security;
alter table public.plans         enable row level security;
alter table public.payments      enable row level security;
alter table public.module_groups enable row level security;

-- المكتب
drop policy if exists org_sel on public.organizations;
create policy org_sel on public.organizations for select to authenticated using (is_member(id));
drop policy if exists org_upd on public.organizations;
create policy org_upd on public.organizations for update to authenticated using (is_owner(id)) with check (is_owner(id));

-- الأعضاء
drop policy if exists mem_sel on public.members;
create policy mem_sel on public.members for select to authenticated using (is_member(org_id));
drop policy if exists mem_upd on public.members;
create policy mem_upd on public.members for update to authenticated
  using (is_owner(org_id) and user_id <> auth.uid()) with check (is_owner(org_id) and user_id <> auth.uid() and role <> 'owner');
drop policy if exists mem_del on public.members;
create policy mem_del on public.members for delete to authenticated using (is_owner(org_id) and user_id <> auth.uid());

-- الدعوات
drop policy if exists inv_all on public.invites;
create policy inv_all on public.invites for all to authenticated using (is_owner(org_id)) with check (is_owner(org_id));

-- السجلات
drop policy if exists rec_sel on public.records;
create policy rec_sel on public.records for select to authenticated using (
  coalesce(perm_level(org_id,t),0) >= 1 and (has_conf(org_id) or not conf_hidden(org_id,t,d)));
drop policy if exists rec_ins on public.records;
create policy rec_ins on public.records for insert to authenticated with check (
  coalesce(perm_level(org_id,t),0) >= 2 and org_active(org_id));
drop policy if exists rec_upd on public.records;
create policy rec_upd on public.records for update to authenticated
  using (coalesce(perm_level(org_id,t),0) >= 2 and org_active(org_id) and (has_conf(org_id) or not conf_hidden(org_id,t,d)))
  with check (coalesce(perm_level(org_id,t),0) >= 2 and org_active(org_id));
drop policy if exists rec_del on public.records;
create policy rec_del on public.records for delete to authenticated using (
  coalesce(perm_level(org_id,t),0) >= 3 and org_active(org_id) and (has_conf(org_id) or not conf_hidden(org_id,t,d)));

-- سجل الأحداث والقوالب
drop policy if exists meta_sel on public.meta;
create policy meta_sel on public.meta for select to authenticated using (is_member(org_id));
drop policy if exists meta_ins on public.meta;
create policy meta_ins on public.meta for insert to authenticated with check (is_member(org_id) and org_active(org_id));
drop policy if exists meta_upd on public.meta;
create policy meta_upd on public.meta for update to authenticated using (is_member(org_id) and org_active(org_id)) with check (is_member(org_id));

-- المرفقات (بيانات الوصف)
drop policy if exists fm_sel on public.files_meta;
create policy fm_sel on public.files_meta for select to authenticated using (coalesce(perm_level(org_id,'cases'),0) >= 1);
drop policy if exists fm_ins on public.files_meta;
create policy fm_ins on public.files_meta for insert to authenticated with check (coalesce(perm_level(org_id,'cases'),0) >= 2 and org_active(org_id));
drop policy if exists fm_del on public.files_meta;
create policy fm_del on public.files_meta for delete to authenticated using (coalesce(perm_level(org_id,'cases'),0) >= 2 and org_active(org_id));

-- الخطط (قراءة للجميع) والمدفوعات (مدير المكتب فقط يقرأ؛ الكتابة من Edge Function فقط)
drop policy if exists plans_sel on public.plans;
create policy plans_sel on public.plans for select to authenticated using (active);
drop policy if exists pay_sel on public.payments;
create policy pay_sel on public.payments for select to authenticated using (is_owner(org_id));
drop policy if exists mg_sel on public.module_groups;
create policy mg_sel on public.module_groups for select to authenticated using (true);

-- ---------- 9) صلاحيات الجداول (منع التلاعب بحالة الاشتراك من المتصفح) ----------
revoke all on all tables in schema public from anon;
revoke insert, update, delete on public.organizations from authenticated;
grant  update (name, vat_no, cr_no, phone, address, role_perms) on public.organizations to authenticated;
revoke insert, update, delete on public.plans, public.payments, public.module_groups from authenticated;
revoke insert on public.members from authenticated;
revoke update on public.members from authenticated;
grant  update (role, status) on public.members to authenticated;

-- ---------- 10) التخزين: حاوية خاصة للمرفقات، المسار: {org_id}/{case_id}/{file} ----------
insert into storage.buckets (id, name, public) values ('files','files',false) on conflict (id) do nothing;

drop policy if exists files_read on storage.objects;
create policy files_read on storage.objects for select to authenticated using (
  bucket_id='files' and coalesce(perm_level(((storage.foldername(name))[1])::uuid,'cases'),0) >= 1);
drop policy if exists files_write on storage.objects;
create policy files_write on storage.objects for insert to authenticated with check (
  bucket_id='files' and coalesce(perm_level(((storage.foldername(name))[1])::uuid,'cases'),0) >= 2
  and org_active(((storage.foldername(name))[1])::uuid));
drop policy if exists files_del on storage.objects;
create policy files_del on storage.objects for delete to authenticated using (
  bucket_id='files' and coalesce(perm_level(((storage.foldername(name))[1])::uuid,'cases'),0) >= 2
  and org_active(((storage.foldername(name))[1])::uuid));

-- ---------- 11) التحديث اللحظي بين مستخدمي المكتب ----------
do $$ begin
  alter publication supabase_realtime add table public.records;
exception when duplicate_object then null; end $$;
