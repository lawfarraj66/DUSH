-- ملحق المحاسبة الشاملة واستوديو التخصيص — نفّذه بعد supabase_schema.sql (مرة واحدة)
-- 1) الوحدات الجديدة تتبع صلاحيات المحاسبة
insert into public.module_groups(t,grp) values ('bank','finance'),('stm','finance') on conflict (t) do nothing;

-- 2) قفل الفترة المحاسبية على مستوى الخادم (التاريخ يُحفظ من شاشة «الموازنة وقفل الفترة» في سجل cfg)
create or replace function public.acct_lock() returns trigger language plpgsql security definer set search_path=public as $$
declare lk text; org uuid:=coalesce(new.org_id,old.org_id); tt text:=coalesce(new.t,old.t); ex boolean;
begin
  if auth.uid() is null or tt not in ('invoices','expenses','je','quotes') then return coalesce(new,old); end if;
  select d->>'lk' into lk from records where org_id=org and t='cfg' limit 1;
  if coalesce(lk,'')='' then return coalesce(new,old); end if;
  if tg_op='DELETE' then
    if coalesce(old.d->>'da','9999')<=lk then raise exception 'الفترة المحاسبية مقفلة حتى %', lk; end if; return old; end if;
  if tg_op='INSERT' then
    select exists(select 1 from records r where r.org_id=new.org_id and r.t=new.t and r.rid=new.rid) into ex;
    if ex then return new; end if;                                   -- upsert على سجل موجود: يعالجه فرع UPDATE
    if coalesce(new.d->>'da','9999')<=lk then raise exception 'لا يمكن إضافة سجل في فترة مقفلة (حتى %)', lk; end if; return new; end if;
  -- UPDATE: يُسمح بتسجيل الدفعات (pd/st/py) على سجل قديم، ويُمنع تغيير التاريخ أو المبلغ أو الضريبة أو العميل
  if coalesce(old.d->>'da','9999')<=lk and ((old.d->>'da') is distinct from (new.d->>'da') or (old.d->>'am') is distinct from (new.d->>'am')
     or (old.d->>'vt') is distinct from (new.d->>'vt') or (old.d->>'cl') is distinct from (new.d->>'cl')) then
    raise exception 'الفترة المحاسبية مقفلة حتى %', lk; end if;
  return new;
end $$;
drop trigger if exists acct_lock_trg on records;
create trigger acct_lock_trg before insert or update or delete on records for each row execute function public.acct_lock();
