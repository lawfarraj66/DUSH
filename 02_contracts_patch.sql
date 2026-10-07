-- يتطلب تنفيذ supabase_schema.sql أولاً. ملحق لقاعدة بياناتك الحالية (لا يعيد إنشاء شيء): نفّذه مرة واحدة في Supabase ← SQL Editor
-- يفرض على الخادم: صلاحيات العقود، قفل المعمّد، منع الحذف، والأرقام المتسلسلة بلا تكرار.

-- 1) لا حاجة لدالة جديدة: نستعمل perm_level(org,'lc') و has_conf(org) الموجودتين في supabase_schema.sql

-- 2) عدّاد أرقام العقود (ذرّي، لكل مكتب وسنة)
create table if not exists contract_counters(org_id uuid, yr int, n int not null default 0, primary key(org_id,yr));
alter table contract_counters enable row level security;   -- بلا سياسات: الوصول عبر الدالة فقط

insert into contract_counters(org_id,yr,n)
select org_id, substring(d->>'no' from 'ع-(\d{4})-')::int, max(substring(d->>'no' from '-(\d+)$')::int)
from records where t='lc' and d->>'no' ~ '^ع-\d{4}-\d+$' group by 1,2
on conflict (org_id,yr) do update set n=greatest(contract_counters.n,excluded.n);

create or replace function next_contract_no(p_org uuid, p_year int default extract(year from now())::int)
returns text language plpgsql security definer set search_path=public as $$
declare v int;
begin
  if coalesce(perm_level(p_org,'lc'),0) < 2 or not org_active(p_org) then raise exception 'لا تملك صلاحية إنشاء العقود'; end if;
  insert into contract_counters(org_id,yr,n) values(p_org,p_year,1)
    on conflict (org_id,yr) do update set n=contract_counters.n+1 returning n into v;
  return 'ع-'||p_year||'-'||lpad(v::text,4,'0');
end $$;
revoke all on function next_contract_no(uuid,int) from public;
grant execute on function next_contract_no(uuid,int) to authenticated;

-- 3) منع تكرار رقم العقد داخل المكتب (إن فشل التنفيذ فهناك أرقام مكررة قديمة: عالجها يدوياً أولاً)
create unique index if not exists lc_no_uq on records(org_id,(d->>'no')) where t='lc' and d->>'no' is not null;

-- 4) حارس العقود على مستوى الخادم
create or replace function lc_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare org uuid := coalesce(new.org_id,old.org_id); lv int; cf boolean; o jsonb; n jsonb; oa text; na text;
begin
  if auth.uid() is null then return coalesce(new,old); end if;           -- خدمات الخادم الموثوقة
  if coalesce(new.t,old.t) not in ('lc','lct') then return coalesce(new,old); end if;
  lv:=coalesce(perm_level(org,'lc'),0); cf:=has_conf(org);
  if tg_op='DELETE' then
    if lv<3 then raise exception 'لا تملك صلاحية حذف العقود'; end if;
    if old.t='lc' and (old.d#>>'{approval,status}')='معتمد' then raise exception 'لا يُحذف عقد معتمد — ألغِه بدلاً من ذلك'; end if;
    return old;
  end if;
  if lv<2 then raise exception 'لا تملك صلاحية تعديل العقود'; end if;
  if new.t<>'lc' then return new; end if;
  -- الصف السابق (الـ upsert يمر أولاً بـ INSERT حتى لو كان الصف موجوداً)
  if tg_op='UPDATE' then o:=old.d; else
    select d into o from records where org_id=new.org_id and t=new.t and rid=new.rid; end if;
  o:=coalesce(o,'{}'::jsonb); n:=new.d;
  oa:=o#>>'{approval,status}'; na:=n#>>'{approval,status}';
  if o->>'no' is not null and (o->>'no') is distinct from (n->>'no') then raise exception 'رقم العقد لا يتغير'; end if;
  if na='معتمد' and coalesce(oa,'')<>'معتمد' and not cf then raise exception 'التعميد للمخوّلين فقط'; end if;
  if oa='معتمد' then
    if na='معتمد' then
      if (o-array['sig','st','ca'])<>(n-array['sig','st','ca']) then raise exception 'العقد معمّد ومقفل للتعديل — اطلب إعادة فتحه'; end if;
    elsif not cf then raise exception 'إعادة فتح العقد المعمّد للمخوّلين فقط'; end if;
  end if;
  if (n->'sig'->'l') is not null and (o->'sig'->'l') is distinct from (n->'sig'->'l') and not cf then
    raise exception 'توقيع المكتب للمخوّلين فقط'; end if;
  if coalesce(o->>'st','')<>'ملغي' and n->>'st'='ملغي' and not cf then raise exception 'إلغاء العقد للمخوّلين فقط'; end if;
  return new;
end $$;
drop trigger if exists lc_guard_trg on records;
create trigger lc_guard_trg before insert or update or delete on records for each row execute function lc_guard();
