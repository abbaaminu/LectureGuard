-- ============================================================================
-- LectureGuard QA: independent RLS / database verification (Phase 2)
-- Written by the QA auditor. Does not modify application source.
-- Target: PostgreSQL 16 with a mock Supabase auth schema.
--
--   psql -X -h 127.0.0.1 -p 55432 -U postgres -d postgres -f qa/rls_verify.sql
--
-- Every check prints its own evidence; the script also raises on any
-- expectation that does not hold so the exit code is meaningful.
-- ============================================================================
\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------------
-- 0. Mock Supabase bootstrap (auth schema + roles + default grants)
-- ---------------------------------------------------------------------------
DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

BEGIN;

DROP SCHEMA IF EXISTS auth CASCADE;
CREATE SCHEMA auth;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Supabase resolves auth.uid() from the JWT; the task specifies request.uid.
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.uid', true), '')::uuid
$$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;

-- Supabase's postgres role grants these by default; without them every
-- authenticated query fails with "permission denied" instead of being
-- filtered by RLS, which would mask policy defects.
GRANT USAGE ON SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated;

\echo '=== Applying migrations 001 -> 002 -> 003 -> 004 in order ==='
\ir ../supabase/migrations/001_lectureguard_schema.sql
\ir ../supabase/migrations/002_fix_rls_and_views.sql
\ir ../supabase/migrations/003_school_settings_and_analytics.sql
\ir ../supabase/migrations/004_harden_teacher_submission_logs.sql

\echo ''
\echo '=== CHECK 8a: CHECK constraints on students / lectures (university use) ==='
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'public.students'::regclass AND contype = 'c';
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'public.lectures'::regclass AND contype = 'c';

-- ---------------------------------------------------------------------------
-- 1. Fixtures
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== Fixtures ==='
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', 'admin@example.test',    '{"full_name":"Ada Admin"}'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'teacher1@example.test', '{"full_name":"Tom Teacher One"}'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'teacher2@example.test', '{"full_name":"Tina Teacher Two"}'),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'student1@example.test', '{"full_name":"Sam Student One"}'),
  ('aaaaaaaa-0000-0000-0000-000000000005', 'student2@example.test', '{"full_name":"Sara Student Two"}');

\echo '--- CHECK 7: profile rows auto-created by the auth.users trigger ---'
SELECT id, full_name, email, role FROM public.profiles ORDER BY id;

UPDATE public.profiles SET role = 'admin'   WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
UPDATE public.profiles SET role = 'teacher' WHERE id IN ('aaaaaaaa-0000-0000-0000-000000000002',
                                                         'aaaaaaaa-0000-0000-0000-000000000003');

-- University use: grade 13 and grade 8, period 11.
INSERT INTO public.students (id, profile_id, student_code, first_name, last_name, grade_level, homeroom) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000004',
   'STU-1', 'Sam', 'Student One', 13, 'Y1-A'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000005',
   'STU-2', 'Sara', 'Student Two', 8, 'B');

INSERT INTO public.lectures (id, course_code, title, teacher_id, room_number, period_number, academic_term) VALUES
  ('cccccccc-0000-0000-0000-000000000001', 'CSC-101', 'Intro CS',
   'aaaaaaaa-0000-0000-0000-000000000002', 'R1', 11, '2026-T1'),
  ('cccccccc-0000-0000-0000-000000000002', 'MAT-102', 'Algebra',
   'aaaaaaaa-0000-0000-0000-000000000003', 'R2', 1, '2026-T1');

INSERT INTO public.enrollments (lecture_id, student_id) VALUES
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001'),
  ('cccccccc-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002');

-- Teacher 1 lecture: 8 sessions. Teacher 2 lecture: 5 sessions.
INSERT INTO public.attendance_sessions (id, lecture_id, teacher_id, session_date, device_id)
SELECT ('dddddddd-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'cccccccc-0000-0000-0000-000000000001',
       'aaaaaaaa-0000-0000-0000-000000000002',
       DATE '2026-09-01' + (n - 1), 'device-1'
FROM generate_series(1, 8) n;

INSERT INTO public.attendance_sessions (id, lecture_id, teacher_id, session_date, device_id)
SELECT ('eeeeeeee-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'cccccccc-0000-0000-0000-000000000002',
       'aaaaaaaa-0000-0000-0000-000000000003',
       DATE '2026-09-01' + (n - 1), 'device-2'
FROM generate_series(1, 5) n;

-- Student 1: present in sessions 1-4, one 'late' in session 5, 'absent' in
-- session 6, and NO record at all in sessions 7-8 (2 implicit absences).
INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
SELECT ('dddddddd-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'cccccccc-0000-0000-0000-000000000001',
       'bbbbbbbb-0000-0000-0000-000000000001', 'present'
FROM generate_series(1, 4) n;
INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
VALUES ('dddddddd-0000-0000-0000-000000000005', 'cccccccc-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001', 'late');
INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
VALUES ('dddddddd-0000-0000-0000-000000000006', 'cccccccc-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001', 'absent');

-- Student 2: present in 4 of 5 sessions (80% -> not chronic at the boundary).
INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
SELECT ('eeeeeeee-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'cccccccc-0000-0000-0000-000000000002',
       'bbbbbbbb-0000-0000-0000-000000000002', 'present'
FROM generate_series(1, 4) n;

\echo '--- Fixture totals (superuser view) ---'
SELECT (SELECT count(*) FROM public.profiles) AS profiles,
       (SELECT count(*) FROM public.students) AS students,
       (SELECT count(*) FROM public.lectures) AS lectures,
       (SELECT count(*) FROM public.enrollments) AS enrollments,
       (SELECT count(*) FROM public.attendance_sessions) AS sessions,
       (SELECT count(*) FROM public.attendance_records) AS records;

-- Helper: run a count as the CURRENT role and report errors instead of
-- aborting the script (proves "no infinite recursion" per object).
CREATE FUNCTION pg_temp.try_count(p_from text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  EXECUTE 'SELECT count(*) FROM ' || p_from INTO n;
  RETURN n::text;
EXCEPTION
  WHEN insufficient_privilege THEN RETURN 'DENIED(42501)';
  WHEN OTHERS THEN RETURN 'ERROR(' || SQLSTATE || '): ' || SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- 2. anon
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 3a: anon table + view access ==='
SET ROLE anon;
SELECT 'anon' AS role,
       pg_temp.try_count('public.profiles')            AS profiles,
       pg_temp.try_count('public.students')            AS students,
       pg_temp.try_count('public.lectures')            AS lectures,
       pg_temp.try_count('public.enrollments')         AS enrollments,
       pg_temp.try_count('public.attendance_sessions') AS sessions,
       pg_temp.try_count('public.attendance_records')  AS records,
       pg_temp.try_count('public.v_student_attendance_summary') AS v_summary,
       pg_temp.try_count('public.v_teacher_submission_logs')    AS v_teacher_logs,
       pg_temp.try_count('public.v_student_weekly_attendance')  AS v_weekly;
SELECT has_table_privilege('anon','public.v_student_attendance_summary','SELECT') AS anon_can_select_summary,
       has_table_privilege('anon','public.v_teacher_submission_logs','SELECT')    AS anon_can_select_logs,
       has_function_privilege('anon','public.teacher_submission_logs(integer,integer)','EXECUTE') AS anon_can_exec_logs_fn;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 3. Teacher 1 (owner of lecture 1 only)
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 1: teacher 1 sees only their own lecture/students/records ==='
SELECT set_config('request.uid', 'aaaaaaaa-0000-0000-0000-000000000002', true);
SET ROLE authenticated;
SELECT 'teacher1' AS role,
       pg_temp.try_count('public.profiles')            AS profiles,
       pg_temp.try_count('public.students')            AS students,
       pg_temp.try_count('public.lectures')            AS lectures,
       pg_temp.try_count('public.enrollments')         AS enrollments,
       pg_temp.try_count('public.attendance_sessions') AS sessions,
       pg_temp.try_count('public.attendance_records')  AS records,
       pg_temp.try_count('public.teacher_submission_logs(1000, 0)') AS v_teacher_logs,
       pg_temp.try_count('public.v_teacher_submission_logs')        AS v_logs_direct,
       pg_temp.try_count('public.v_student_attendance_summary') AS v_summary;
\echo '--- teacher 1 visible lectures (CSC-101 only) ---'
SELECT course_code, title, teacher_id FROM public.lectures ORDER BY course_code;
\echo '--- teacher 1 visible sessions per lecture (8 / 0 expected) ---'
SELECT lecture_id, count(*) FROM public.attendance_sessions GROUP BY lecture_id ORDER BY 1;

\echo ''
\echo '=== CHECK 6: teacher write restrictions (all three must be rejected) ==='
DO $$
BEGIN
  BEGIN
    INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
    VALUES ('dddddddd-0000-0000-0000-000000000001',
            'cccccccc-0000-0000-0000-000000000001',
            'bbbbbbbb-0000-0000-0000-000000000002', 'present');
    RAISE NOTICE 'FAIL: unenrolled-student insert was ACCEPTED';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'REJECTED: record for a student not enrolled in my lecture';
  END;

  BEGIN
    INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
    VALUES ('eeeeeeee-0000-0000-0000-000000000001',
            'cccccccc-0000-0000-0000-000000000001',
            'bbbbbbbb-0000-0000-0000-000000000001', 'present');
    RAISE NOTICE 'FAIL: cross-teacher-session insert was ACCEPTED';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'REJECTED: record pointing at another teacher session';
  END;

  BEGIN
    INSERT INTO public.attendance_records (
      session_id, lecture_id, student_id, status, override_by, override_reason)
    VALUES ('dddddddd-0000-0000-0000-000000000007',
            'cccccccc-0000-0000-0000-000000000001',
            'bbbbbbbb-0000-0000-0000-000000000001', 'present',
            'aaaaaaaa-0000-0000-0000-000000000001', 'x');
    RAISE NOTICE 'FAIL: override attributed to another profile was ACCEPTED';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'REJECTED: override_by pointing at another profile';
  END;

  BEGIN
    INSERT INTO public.attendance_records (
      session_id, lecture_id, student_id, status, override_by, override_reason)
    VALUES ('dddddddd-0000-0000-0000-000000000007',
            'cccccccc-0000-0000-0000-000000000001',
            'bbbbbbbb-0000-0000-0000-000000000001', 'present',
            'aaaaaaaa-0000-0000-0000-000000000002', 'late bus');
    RAISE NOTICE 'ACCEPTED (expected): own session, enrolled student, own override_by';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'FAIL: legitimate insert for own session was REJECTED';
  END;
END $$;
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 4. Student 1
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 2: student 1 sees only their own records and lectures ==='
SELECT set_config('request.uid', 'aaaaaaaa-0000-0000-0000-000000000004', true);
SET ROLE authenticated;
SELECT 'student1' AS role,
       pg_temp.try_count('public.profiles')            AS profiles,
       pg_temp.try_count('public.students')            AS students,
       pg_temp.try_count('public.lectures')            AS lectures,
       pg_temp.try_count('public.enrollments')         AS enrollments,
       pg_temp.try_count('public.attendance_sessions') AS sessions,
       pg_temp.try_count('public.attendance_records')  AS records,
       pg_temp.try_count('public.teacher_submission_logs(1000, 0)') AS v_teacher_logs,
       pg_temp.try_count('public.v_teacher_submission_logs')        AS v_logs_direct,
       pg_temp.try_count('public.v_student_attendance_summary') AS v_summary;
\echo '--- student 1 must see 0 rows belonging to student 2 / lecture 2 ---'
SELECT (SELECT count(*) FROM public.attendance_records
        WHERE student_id <> 'bbbbbbbb-0000-0000-0000-000000000001') AS other_student_records,
       (SELECT count(*) FROM public.lectures
        WHERE id = 'cccccccc-0000-0000-0000-000000000002')         AS other_lecture,
       (SELECT count(*) FROM public.attendance_sessions
        WHERE lecture_id = 'cccccccc-0000-0000-0000-000000000002') AS other_lecture_sessions;
RESET ROLE;

-- Remove the row created by the CHECK 6 positive test so the summary numbers
-- below are computed from the pristine fixture.
DELETE FROM public.attendance_records
WHERE session_id = 'dddddddd-0000-0000-0000-000000000007'
  AND student_id = 'bbbbbbbb-0000-0000-0000-000000000001';

-- ---------------------------------------------------------------------------
-- 5. Admin
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== CHECK 4: admin sees everything ==='
SELECT set_config('request.uid', 'aaaaaaaa-0000-0000-0000-000000000001', true);
SET ROLE authenticated;
SELECT 'admin' AS role,
       pg_temp.try_count('public.profiles')            AS profiles,
       pg_temp.try_count('public.students')            AS students,
       pg_temp.try_count('public.lectures')            AS lectures,
       pg_temp.try_count('public.enrollments')         AS enrollments,
       pg_temp.try_count('public.attendance_sessions') AS sessions,
       pg_temp.try_count('public.attendance_records')  AS records,
       pg_temp.try_count('public.teacher_submission_logs(1000, 0)') AS v_teacher_logs,
       pg_temp.try_count('public.v_teacher_submission_logs')        AS v_logs_direct,
       pg_temp.try_count('public.v_student_attendance_summary') AS v_summary,
       pg_temp.try_count('public.v_student_weekly_attendance')  AS v_weekly,
       pg_temp.try_count('public.school_settings')     AS settings;

\echo ''
\echo '=== CHECK 8b: university grade_level (13) and period_number (11) accepted ==='
SELECT student_code, grade_level FROM public.students ORDER BY student_code;
SELECT course_code, period_number FROM public.lectures ORDER BY course_code;

\echo ''
\echo '=== CHECK 5: missing record = absence, and <80% => chronic_absenteeism_flag ==='
SELECT student_id, student_code, total_sessions, attended_sessions,
       unexcused_absences, late_count, attendance_percentage,
       chronic_absenteeism_flag
FROM public.v_student_attendance_summary
ORDER BY student_code;

\echo '--- cross-check: enrolled sessions vs own records per student ---'
SELECT s.student_code,
       count(ats.id)                                   AS enrolled_sessions,
       count(ar.id)                                    AS own_records,
       count(ats.id) - count(ar.id)                    AS sessions_without_record
FROM public.students s
JOIN public.enrollments e ON e.student_id = s.id AND e.active
JOIN public.attendance_sessions ats ON ats.lecture_id = e.lecture_id
LEFT JOIN public.attendance_records ar
       ON ar.session_id = ats.id AND ar.student_id = s.id
GROUP BY s.student_code
ORDER BY s.student_code;

\echo '--- admin chronic page (>1000 row pagination smoke: function callable) ---'
SELECT count(*) AS chronic_rows
FROM public.admin_chronic_absentee_page(NULL, NULL, NULL, NULL);
RESET ROLE;

\echo ''
\echo '=== CHECK 3b: anon view grant state (views must be revoked from anon) ==='
SELECT 'anon' AS role,
       has_table_privilege('anon','public.v_student_attendance_summary','SELECT') AS summary_grant,
       has_table_privilege('anon','public.v_teacher_submission_logs','SELECT')    AS logs_grant,
       has_function_privilege('anon','public.teacher_submission_logs(integer,integer)','EXECUTE') AS logs_fn_grant;

\echo '--- CHECK 3c: the staff log function returns rows only for staff ---'
SELECT 'authenticated' AS role,
       has_table_privilege('authenticated','public.v_teacher_submission_logs','SELECT') AS logs_grant,
       has_function_privilege('authenticated','public.teacher_submission_logs(integer,integer)','EXECUTE') AS logs_fn_grant;
SELECT set_config('request.uid', 'aaaaaaaa-0000-0000-0000-000000000004', true);
SET ROLE authenticated;
SELECT count(*) AS student_rows FROM public.teacher_submission_logs(1000, 0);
SELECT count(*) AS student_summary_rows FROM public.v_student_attendance_summary;
RESET ROLE;
SELECT set_config('request.uid', 'aaaaaaaa-0000-0000-0000-000000000002', true);
SET ROLE authenticated;
SELECT count(*) AS teacher_rows, min(course_code) AS only_course
FROM public.teacher_submission_logs(1000, 0);
RESET ROLE;

ROLLBACK;
\echo 'rls_verify.sql completed without aborting'


