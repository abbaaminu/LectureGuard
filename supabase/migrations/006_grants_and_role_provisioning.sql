-- ============================================================================
-- 006 — Table privileges and automatic profile/role provisioning
--
-- Two defects made signed-in accounts fail with
-- "permission denied for table profiles" (and, on the reporting screens,
-- "... for table students"):
--
-- 1. Migrations 001-005 created the tables and the RLS policies but never
--    granted table privileges to the `anon` and `authenticated` roles. RLS
--    filters rows; it does not hand out access to a table. The integration
--    test granted the privileges itself (because it has to bootstrap a bare
--    PostgreSQL server), so the omission never showed up in CI. Inside the
--    Supabase project only the table owner could read the data, and every
--    anon-key request was rejected before a policy was evaluated. The
--    reporting views (`security_invoker = true`) and
--    `admin_chronic_absentee_page()` (SECURITY INVOKER) failed the same way.
--
-- 2. A profile row was only created for auth users inserted after migration
--    002, always as `student`. Accounts created before that trigger existed
--    had no profile at all, and there was no supported way to assign a
--    teacher/admin role other than editing `public.profiles` by hand. Until
--    that manual edit happened the app showed "Your account does not have a
--    school profile yet" (or an unsupported role).
--
-- This migration is additive and idempotent: it grants privileges, backfills
-- missing profile rows, and replaces the sign-up trigger plus its two
-- provisioning helpers. It deletes no rows and overwrites no existing role.
--
-- Apply with the Supabase CLI (`supabase db push`) or paste it into the
-- dashboard SQL editor as the `postgres` role.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Schema and table privileges
-- ----------------------------------------------------------------------------

GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Re-assert RLS before handing `anon` any read access. The policies return zero
-- rows for an anonymous client, and this keeps that true even if a table was
-- recreated without its RLS flag (ALTER ... ENABLE is a no-op when already on).
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lectures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_records ENABLE ROW LEVEL SECURITY;

-- `anon` may run SELECT so that an unauthenticated request is answered with an
-- empty result set (every policy needs auth.uid()), instead of a 401 that the
-- screens render as "permission denied for table ...". Writes stay with
-- `authenticated`; RLS still decides which rows/columns of a write are legal.
GRANT SELECT ON TABLE
  public.profiles,
  public.students,
  public.lectures,
  public.enrollments,
  public.attendance_sessions,
  public.attendance_records
  TO anon, authenticated;

GRANT INSERT, UPDATE, DELETE ON TABLE
  public.profiles,
  public.students,
  public.lectures,
  public.enrollments,
  public.attendance_sessions,
  public.attendance_records
  TO authenticated;

-- No table uses a serial/bigserial primary key today, but attendance devices
-- and future tables may, and a sequence the client cannot touch fails an
-- INSERT at sync time.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Defaults for tables/sequences created by later migrations, so a new table is
-- usable by signed-in clients without a second GRANT. `anon` is deliberately
-- excluded: only the six tables above are readable without a session.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. Views and settings stay unreadable for anonymous clients
-- ----------------------------------------------------------------------------

-- These were already granted by 002/003; repeating them documents that 006
-- keeps the anonymous revocations intact.
GRANT SELECT ON TABLE public.v_student_attendance_summary,
  public.v_student_weekly_attendance
  TO authenticated;
REVOKE ALL ON TABLE public.v_student_attendance_summary,
  public.v_student_weekly_attendance,
  public.v_teacher_submission_logs
  FROM anon, PUBLIC;

GRANT SELECT, UPDATE ON TABLE public.school_settings TO authenticated;
REVOKE ALL ON TABLE public.school_settings FROM anon, PUBLIC;

-- ----------------------------------------------------------------------------
-- 3. RLS helper functions
--
-- The policies call these functions while running as the requesting role, so
-- that role needs EXECUTE. They were relying on the implicit PUBLIC grant;
-- granting explicitly keeps working if PUBLIC is ever revoked.
-- ----------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.current_user_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.my_student_id() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.teaches_lecture(uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_enrolled_in(uuid, uuid) TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.teacher_submission_logs(integer, integer)
  TO authenticated;
REVOKE ALL ON FUNCTION public.teacher_submission_logs(integer, integer)
  FROM anon, PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_chronic_absentee_page(
  text, smallint, date, date
) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_chronic_absentee_page(
  text, smallint, date, date
) FROM anon, PUBLIC;

-- ----------------------------------------------------------------------------
-- 4. Role names and the sign-up trigger
-- ----------------------------------------------------------------------------

-- Maps a stored role name to the enum. Unknown or missing values fall back to
-- `student` (least privilege) instead of failing a sign-up; the app already
-- treats an unrecognised profile role as "no access".
CREATE OR REPLACE FUNCTION public.role_from_name(p_role text)
RETURNS public.user_role
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE lower(btrim(COALESCE(p_role, '')))
    WHEN 'admin' THEN 'admin'::public.user_role
    WHEN 'teacher' THEN 'teacher'::public.user_role
    ELSE 'student'::public.user_role
  END
$$;

COMMENT ON FUNCTION public.role_from_name(text) IS
  'Maps admin/teacher/student (case-insensitive) to the role enum; anything else becomes student.';

-- New auth accounts always receive a profile row, so the app never has to
-- guess. The role is taken from `raw_app_meta_data`, which only the service
-- role / dashboard administrator can write. `raw_user_meta_data` is
-- self-asserted during sign-up and is used for the display name only, so a
-- public sign-up cannot promote itself.
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email, role)
  VALUES (
    NEW.id,
    COALESCE(
      NULLIF(NEW.raw_user_meta_data ->> 'full_name', ''),
      NULLIF(NEW.raw_user_meta_data ->> 'name', ''),
      NULLIF(split_part(COALESCE(NEW.email, ''), '@', 1), ''),
      NEW.id::text
    ),
    COALESCE(NEW.email, NEW.id::text || '@no-email.invalid'),
    public.role_from_name(
      COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) ->> 'role'
    )
  )
  -- A duplicate email must never make user creation fail; the affected
  -- account then shows the access message until an administrator resolves it.
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- Dashboard and Admin API role changes update the profile as well, so an
-- administrator does not have to edit the profiles table by hand.
CREATE OR REPLACE FUNCTION public.sync_profile_role_from_app_metadata()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := lower(btrim(COALESCE(NEW.raw_app_meta_data ->> 'role', '')));
BEGIN
  IF NEW.raw_app_meta_data IS DISTINCT FROM OLD.raw_app_meta_data
     AND v_role IN ('admin', 'teacher', 'student') THEN
    UPDATE public.profiles
    SET role = public.role_from_name(v_role),
        updated_at = NOW()
    WHERE id = NEW.id
      AND role IS DISTINCT FROM public.role_from_name(v_role);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_role_changed ON auth.users;
CREATE TRIGGER on_auth_user_role_changed
  AFTER UPDATE OF raw_app_meta_data ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.sync_profile_role_from_app_metadata();

-- ----------------------------------------------------------------------------
-- 5. Backfill for accounts that exist without a profile
--
-- Run from the SQL editor (postgres) or the service role after a bulk import.
-- Clients cannot execute it: it reads auth.users and would leak account data.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.backfill_profiles_from_auth_users()
RETURNS integer
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_inserted integer;
BEGIN
  INSERT INTO public.profiles (id, full_name, email, role)
  SELECT
    u.id,
    COALESCE(
      NULLIF(u.raw_user_meta_data ->> 'full_name', ''),
      NULLIF(u.raw_user_meta_data ->> 'name', ''),
      NULLIF(split_part(COALESCE(u.email, ''), '@', 1), ''),
      u.id::text
    ),
    COALESCE(u.email, u.id::text || '@no-email.invalid'),
    public.role_from_name(
      COALESCE(u.raw_app_meta_data, '{}'::jsonb) ->> 'role'
    )
  FROM auth.users AS u
  WHERE NOT EXISTS (
    SELECT 1 FROM public.profiles AS p WHERE p.id = u.id
  )
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

COMMENT ON FUNCTION public.backfill_profiles_from_auth_users() IS
  'Creates the missing public.profiles rows for auth.users; returns the number inserted.';

REVOKE ALL ON FUNCTION public.backfill_profiles_from_auth_users()
  FROM PUBLIC, anon, authenticated;

-- Existing accounts (created before the trigger, or by the dashboard while the
-- trigger was missing) get their profile now.
SELECT public.backfill_profiles_from_auth_users();

-- ----------------------------------------------------------------------------
-- 6. Administrator role assignment
--
-- `select public.admin_set_user_role('teacher@school.edu', 'teacher');`
-- from the SQL editor, or from an admin session. Runs as the caller, so the
-- profiles RLS admin policy remains the second line of defence.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_set_user_role(
  p_email text,
  p_role public.user_role
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT (
    public.current_user_role() = 'admin'
    OR current_user IN ('postgres', 'supabase_admin', 'service_role')
  ) THEN
    RAISE EXCEPTION 'Only an administrator can change account roles.'
      USING ERRCODE = '42501';
  END IF;

  IF p_email IS NULL OR btrim(p_email) = '' THEN
    RAISE EXCEPTION 'An account email address is required.';
  END IF;

  SELECT p.id INTO v_id
  FROM public.profiles AS p
  WHERE lower(p.email) = lower(btrim(p_email));

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'No profile exists for %; create the auth user first.',
      p_email
      USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.profiles
  SET role = p_role,
      updated_at = NOW()
  WHERE id = v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.admin_set_user_role(text, public.user_role) IS
  'Assigns admin/teacher/student to the profile matching an email address.';

REVOKE ALL ON FUNCTION public.admin_set_user_role(text, public.user_role)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_user_role(text, public.user_role)
  TO authenticated;
