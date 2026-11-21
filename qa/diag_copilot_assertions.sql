-- Diagnostic: replicate supabase/tests/rls_test.sql fixtures and PRINT the
-- counts that its student block (lines 196-234) asserts, so the failing
-- expectation can be identified precisely.
\set ON_ERROR_STOP on
\pset pager off

DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

BEGIN;

DROP SCHEMA IF EXISTS auth CASCADE;
CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;

GRANT USAGE ON SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated;

\ir ../supabase/migrations/001_lectureguard_schema.sql
\ir ../supabase/migrations/002_fix_rls_and_views.sql
\ir ../supabase/migrations/003_school_settings_and_analytics.sql

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('00000000-0000-0000-0000-000000000001', 'admin@example.test', '{"full_name":"Admin"}'),
  ('00000000-0000-0000-0000-000000000002', 'teacher1@example.test', '{"full_name":"Teacher One"}'),
  ('00000000-0000-0000-0000-000000000003', 'teacher2@example.test', '{"full_name":"Teacher Two"}'),
  ('00000000-0000-0000-0000-000000000004', 'student1@example.test', '{"full_name":"Student One"}'),
  ('00000000-0000-0000-0000-000000000005', 'student2@example.test', '{"full_name":"Student Two"}');
UPDATE public.profiles SET role = 'admin'   WHERE id = '00000000-0000-0000-0000-000000000001';
UPDATE public.profiles SET role = 'teacher' WHERE id IN ('00000000-0000-0000-0000-000000000002',
                                                         '00000000-0000-0000-0000-000000000003');

INSERT INTO public.students (id, profile_id, student_code, first_name, last_name, grade_level, homeroom)
VALUES
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', 'STU-1', 'Student', 'One', 13, 'A'),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000005', 'STU-2', 'Student', 'Two', 8, 'B');

INSERT INTO public.lectures (id, course_code, title, teacher_id, room_number, period_number, academic_term)
VALUES
  ('20000000-0000-0000-0000-000000000001', 'BIO-1', 'Biology One', '00000000-0000-0000-0000-000000000002', 'A1', 11, '2026-T1'),
  ('20000000-0000-0000-0000-000000000002', 'BIO-2', 'Biology Two', '00000000-0000-0000-0000-000000000003', 'B1', 1, '2026-T1');

INSERT INTO public.enrollments (lecture_id, student_id) VALUES
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002');

INSERT INTO public.attendance_sessions (id, lecture_id, teacher_id, session_date, device_id)
SELECT ('30000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       '20000000-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-000000000002',
       DATE '2026-10-01' + (n - 1), 'device-1'
FROM generate_series(1, 5) n;
INSERT INTO public.attendance_sessions (id, lecture_id, teacher_id, session_date, device_id)
VALUES ('30000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002',
        '00000000-0000-0000-0000-000000000003', DATE '2026-10-01', 'device-2');

INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
SELECT ats.id, ats.lecture_id, '10000000-0000-0000-0000-000000000001', 'present'
FROM public.attendance_sessions AS ats
WHERE ats.lecture_id = '20000000-0000-0000-0000-000000000001'
  AND ats.session_date <= DATE '2026-10-02';
INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
VALUES ('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000001',
        '10000000-0000-0000-0000-000000000001', 'excused');
INSERT INTO public.attendance_records (session_id, lecture_id, student_id, status)
VALUES ('30000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002',
        '10000000-0000-0000-0000-000000000002', 'present');

\echo '--- rows per student as superuser (owner, RLS bypassed) ---'
SELECT student_id, status, count(*) FROM public.attendance_records GROUP BY 1, 2 ORDER BY 1, 2;

SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
SET ROLE authenticated;
\echo '--- what STUDENT 1 actually sees (rls_test.sql lines 200-206 assert 1/1/1/5/4/1/5) ---'
SELECT (SELECT count(*) FROM public.students)            AS students_actual,
       (SELECT count(*) FROM public.lectures)            AS lectures_actual,
       (SELECT count(*) FROM public.enrollments)         AS enrollments_actual,
       (SELECT count(*) FROM public.attendance_sessions) AS sessions_actual,
       (SELECT count(*) FROM public.attendance_records)  AS records_actual,
       (SELECT count(*) FROM public.school_settings)     AS settings_actual,
       (SELECT count(*) FROM public.v_teacher_submission_logs) AS v_logs_actual,
       (SELECT count(*) FROM public.v_student_attendance_summary) AS v_summary_actual,
       (SELECT count(*) FROM public.profiles)            AS profiles_actual;
RESET ROLE;

\echo '--- desired vs actual (rls_test.sql expectations) ---'
SELECT expected_items.item, expected_items.expected
FROM (VALUES
  ('students', 1), ('lectures', 1), ('enrollments', 1), ('sessions', 5),
  ('records', 4), ('school_settings', 1), ('v_teacher_submission_logs', 5)
) AS expected_items(item, expected);

ROLLBACK;
