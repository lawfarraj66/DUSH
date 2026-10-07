-- ============================================================
-- COMPLETE SCHEMA FOR LAW FIRM MANAGEMENT APP
-- ============================================================
-- This is the main schema file. Run this FIRST in Supabase.
-- Copy and paste into SQL Editor, then click "Run"
-- ============================================================

BEGIN;

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- 1. Core Tables: Organizations & Team
-- ============================================================

CREATE TABLE IF NOT EXISTS organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  email text UNIQUE NOT NULL,
  phone text,
  address text,
  status text DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'inactive')),
  created_at timestamp DEFAULT now(),
  updated_at timestamp DEFAULT now()
);

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;

CREATE POLICY org_select ON organizations
  FOR SELECT USING (true);

CREATE POLICY org_owner ON organizations
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM members m
      WHERE m.org_id = organizations.id
        AND m.user_id = auth.uid()
        AND m.role IN ('owner', 'admin')
    )
  );

-- Members table
CREATE TABLE IF NOT EXISTS members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text,
  role text DEFAULT 'staff' CHECK (role IN ('owner', 'manager', 'admin', 'lawyer', 'staff', 'employee')),
  status text DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'pending')),
  created_at timestamp DEFAULT now(),
  UNIQUE(org_id, user_id)
);

ALTER TABLE members ENABLE ROW LEVEL SECURITY;

CREATE POLICY member_select ON members
  FOR SELECT USING (
    org_id IN (
      SELECT org_id FROM members WHERE user_id = auth.uid()
    )
  );

-- ============================================================
-- 2. Permission Helper Functions
-- ============================================================

CREATE OR REPLACE FUNCTION org_active(p_org uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS(
    SELECT 1 FROM organizations
    WHERE id = p_org AND status = 'active'
  );
$$;

CREATE OR REPLACE FUNCTION has_conf(p_org uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS(
    SELECT 1 FROM members m
    WHERE m.org_id = p_org
      AND m.user_id = auth.uid()
      AND m.status = 'active'
      AND m.role IN ('owner', 'manager', 'admin')
  );
$$;

CREATE OR REPLACE FUNCTION perm_level(p_org uuid, p_feature text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_level integer := 0;
BEGIN
  IF p_org IS NULL THEN
    RETURN 0;
  END IF;

  SELECT LOWER(m.role) INTO v_role
  FROM members m
  WHERE m.org_id = p_org
    AND m.user_id = auth.uid()
    AND m.status = 'active'
  LIMIT 1;

  IF v_role IS NULL THEN
    RETURN 0;
  END IF;

  IF v_role = 'owner' THEN
    v_level := 3;
  ELSIF v_role IN ('manager', 'admin') THEN
    v_level := 2;
  ELSIF v_role IN ('lawyer', 'staff', 'employee') THEN
    v_level := 1;
  ELSE
    v_level := 0;
  END IF;

  RETURN v_level;
END;
$$;

-- ============================================================
-- 3. Records Table (Generic/Flexible Schema)
-- ============================================================

CREATE TABLE IF NOT EXISTS records (
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  t text NOT NULL,
  rid text NOT NULL,
  o integer NOT NULL DEFAULT 0,
  d jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_by uuid,
  updated_at timestamp DEFAULT now(),
  PRIMARY KEY (org_id, t, rid)
);

ALTER TABLE records ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS records_org_t_idx ON records(org_id, t);
CREATE INDEX IF NOT EXISTS records_org_updated_idx ON records(org_id, updated_at DESC);

CREATE POLICY records_select ON records
  FOR SELECT USING (
    org_id IN (
      SELECT org_id FROM members WHERE user_id = auth.uid()
    )
  );

CREATE POLICY records_insert ON records
  FOR INSERT WITH CHECK (
    org_id IN (
      SELECT org_id FROM members WHERE user_id = auth.uid() AND status = 'active'
    )
  );

CREATE POLICY records_update ON records
  FOR UPDATE USING (
    org_id IN (
      SELECT org_id FROM members WHERE user_id = auth.uid() AND status = 'active'
    )
  );

CREATE POLICY records_delete ON records
  FOR DELETE USING (
    org_id IN (
      SELECT org_id FROM members WHERE user_id = auth.uid() AND status = 'active'
    )
  );

-- ============================================================
-- 4. Files Storage Metadata
-- ============================================================

CREATE TABLE IF NOT EXISTS files_meta (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  ca text NOT NULL,
  name text NOT NULL,
  type text,
  size integer,
  da text,
  path text NOT NULL UNIQUE,
  created_at timestamp DEFAULT now()
);

ALTER TABLE files_meta ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS files_meta_org_ca_idx ON files_meta(org_id, ca);

CREATE POLICY files_meta_select ON files_meta
  FOR SELECT USING (
    org_id IN (
      SELECT org_id FROM members WHERE user_id = auth.uid()
    )
  );

CREATE POLICY files_meta_insert ON files_meta
  FOR INSERT WITH CHECK (
    org_id IN (
      SELECT org_id FROM members WHERE user_id = auth.uid() AND status = 'active'
    )
  );

-- ============================================================
-- 5. Automatic Trigger: Create Member on Signup
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  org_id_val uuid;
  is_first boolean;
BEGIN
  -- Check if there's an organization with this email
  SELECT id INTO org_id_val
  FROM organizations
  WHERE email = NEW.email
  LIMIT 1;

  -- If no org found by email, create one
  IF org_id_val IS NULL THEN
    INSERT INTO organizations (name, email, status)
    VALUES (
      COALESCE(NEW.raw_user_meta_data->>'office_name', 'مكتب جديد'),
      NEW.email,
      'active'
    )
    RETURNING id INTO org_id_val;
    is_first := true;
  ELSE
    is_first := false;
  END IF;

  -- Create member record
  INSERT INTO members (org_id, user_id, full_name, role, status)
  VALUES (
    org_id_val,
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email),
    CASE WHEN is_first THEN 'owner' ELSE 'staff' END,
    'active'
  )
  ON CONFLICT (org_id, user_id) DO UPDATE
  SET status = 'active', role = CASE WHEN is_first THEN 'owner' ELSE members.role END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

COMMIT;
