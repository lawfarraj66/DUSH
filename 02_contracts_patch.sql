-- ==========================================================
-- FINAL SAFE CONTRACT PATCH FOR LAW FIRM APP
-- ==========================================================
-- Run this AFTER schema file
-- Safe to rerun multiple times
-- ==========================================================

BEGIN;

CREATE TABLE IF NOT EXISTS contract_counters (
  org_id uuid NOT NULL,
  yr int NOT NULL,
  n int NOT NULL DEFAULT 0,
  PRIMARY KEY (org_id, yr)
);

ALTER TABLE contract_counters ENABLE ROW LEVEL SECURITY;

INSERT INTO contract_counters(org_id, yr, n)
SELECT
  r.org_id,
  (regexp_match(r.d->>'no', '^ع-([0-9]{4})-[0-9]+$'))[1]::int AS yr,
  max((regexp_match(r.d->>'no', '^ع-[0-9]{4}-([0-9]+)$'))[1]::int) AS max_num
FROM records r
WHERE r.t = 'lc'
  AND r.d->>'no' ~ '^ع-[0-9]{4}-[0-9]+$'
GROUP BY r.org_id, (regexp_match(r.d->>'no', '^ع-([0-9]{4})-[0-9]+$'))[1]::int
ON CONFLICT (org_id, yr)
DO UPDATE SET n = greatest(contract_counters.n, excluded.n);

CREATE OR REPLACE FUNCTION next_contract_no(p_org uuid, p_year int DEFAULT extract(year from now())::int)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v int;
BEGIN
  IF coalesce(perm_level(p_org, 'lc'), 0) < 2 THEN
    RAISE EXCEPTION 'لا تملك صلاحية إنشاء العقود';
  END IF;

  IF NOT org_active(p_org) THEN
    RAISE EXCEPTION 'المكتب غير نشط';
  END IF;

  INSERT INTO contract_counters(org_id, yr, n)
  VALUES (p_org, p_year, 1)
  ON CONFLICT (org_id, yr)
  DO UPDATE SET n = contract_counters.n + 1
  RETURNING n INTO v;

  RETURN 'ع-' || p_year || '-' || lpad(v::text, 4, '0');
END;
$$;

REVOKE ALL ON FUNCTION next_contract_no(uuid, int) FROM public;
GRANT EXECUTE ON FUNCTION next_contract_no(uuid, int) TO authenticated;

CREATE UNIQUE INDEX IF NOT EXISTS lc_no_uq
ON records(org_id, (d->>'no'))
WHERE t = 'lc' AND d->>'no' IS NOT NULL;

CREATE OR REPLACE FUNCTION lc_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org_id_val uuid := coalesce(new.org_id, old.org_id);
  lv int;
  cf boolean;
  old_d jsonb;
  new_d jsonb;
  old_app text;
  new_app text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN coalesce(new, old);
  END IF;

  IF coalesce(new.t, old.t) NOT IN ('lc', 'lct') THEN
    RETURN coalesce(new, old);
  END IF;

  lv := coalesce(perm_level(org_id_val, 'lc'), 0);
  cf := has_conf(org_id_val);

  IF tg_op = 'DELETE' THEN
    IF lv < 3 THEN
      RAISE EXCEPTION 'لا تملك صلاحية حذف العقود';
    END IF;

    IF old.t = 'lc' AND coalesce(old.d#>>'{approval,status}', '') = 'معتمد' THEN
      RAISE EXCEPTION 'لا يُحذف عقد معتمد — ألغِه بدلاً من ذلك';
    END IF;

    RETURN old;
  END IF;

  IF lv < 2 THEN
    RAISE EXCEPTION 'لا تملك صلاحية تعديل العقود';
  END IF;

  IF new.t <> 'lc' THEN
    RETURN new;
  END IF;

  IF tg_op = 'UPDATE' THEN
    old_d := coalesce(old.d, '{}'::jsonb);
  ELSE
    SELECT d INTO old_d
    FROM records
    WHERE org_id = new.org_id
      AND t = new.t
      AND rid = new.rid;
  END IF;

  old_d := coalesce(old_d, '{}'::jsonb);
  new_d := new.d;

  old_app := old_d#>>'{approval,status}';
  new_app := new_d#>>'{approval,status}';

  IF (old_d->>'no') IS NOT NULL AND (old_d->>'no') IS DISTINCT FROM (new_d->>'no') THEN
    RAISE EXCEPTION 'رقم العقد لا يتغير';
  END IF;

  IF new_app = 'معتمد' AND coalesce(old_app, '') <> 'معتمد' AND NOT cf THEN
    RAISE EXCEPTION 'التعميد للمخوّلين فقط';
  END IF;

  IF coalesce(old_app, '') = 'معتمد' THEN
    IF new_app = 'معتمد' THEN
      IF old_d->'sig' IS DISTINCT FROM new_d->'sig'
        OR old_d->'st' IS DISTINCT FROM new_d->'st'
        OR old_d->'ca' IS DISTINCT FROM new_d->'ca'
      THEN
        RAISE EXCEPTION 'العقد معمّد ومقفل للتعديل — اطلب إعادة فتحه';
      END IF;
    ELSIF NOT cf THEN
      RAISE EXCEPTION 'إعادة فتح العقد المعمّد للمخوّلين فقط';
    END IF;
  END IF;

  IF (new_d->'sig'->'l') IS NOT NULL
     AND (old_d->'sig'->'l') IS DISTINCT FROM (new_d->'sig'->'l')
     AND NOT cf THEN
    RAISE EXCEPTION 'توقيع المكتب للمخوّلين فقط';
  END IF;

  IF coalesce(old_d->>'st', '') <> 'ملغي'
     AND new_d->>'st' = 'ملغي'
     AND NOT cf
  THEN
    RAISE EXCEPTION 'إلغاء العقد للمخوّلين فقط';
  END IF;

  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS lc_guard_trg ON records;
CREATE TRIGGER lc_guard_trg
BEFORE INSERT OR UPDATE OF d OR DELETE ON records
FOR EACH ROW
EXECUTE FUNCTION lc_guard();

COMMIT;
